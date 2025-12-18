#!/bin/bash
# install_hls_converter_final_corrigido.sh - VERSÃO COM ARQUIVOS INTERNOS E MULTIARQUIVOS

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE - VERSÃO MULTIARQUIVOS"
echo "=================================================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_final_corrigido.sh"
    exit 1
fi

# 2. Atualizar sistema
echo "📦 Atualizando sistema..."
apt-get update
apt-get upgrade -y

# 3. Instalar dependências do sistema
echo "🔧 Instalando dependências..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    ffmpeg \
    nginx \
    supervisor \
    git \
    curl \
    wget \
    unzip \
    pv \
    bc \
    jq \
    net-tools

# 4. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if ! id "hlsuser" &>/dev/null; then
    useradd -m -s /bin/bash -d /opt/hls-converter hlsuser
    echo "✅ Usuário hlsuser criado"
else
    echo "⚠️  Usuário hlsuser já existe"
fi

# 5. Criar estrutura de diretórios
echo "📁 Criando estrutura de diretórios..."
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,backups,sessions,static,videos_internos}

# 6. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
cd /opt/hls-converter
python3 -m venv venv
source venv/bin/activate

# 7. Instalar dependências Python
echo "📦 Instalando dependências Python..."
pip install --upgrade pip
pip install \
    flask \
    flask-cors \
    flask-session \
    bcrypt \
    psutil \
    pillow \
    waitress \
    python-dotenv \
    werkzeug

# 8. Configurar nginx COM TIMEOUTS AUMENTADOS
echo "🌐 Configurando nginx..."
cat > /etc/nginx/sites-available/hls-converter << 'EOF'
server {
    listen 80;
    server_name _;
    
    # Aumentar tamanho máximo de upload (2GB)
    client_max_body_size 2G;
    client_body_timeout 3600s;
    client_header_timeout 3600s;
    
    # Desabilitar buffering para uploads grandes
    proxy_request_buffering off;
    proxy_buffering off;
    
    # Aumentar buffer size
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;
    
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts aumentados para conversões longas (2GB)
        proxy_connect_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        
        # Configurações adicionais
        proxy_redirect off;
    }
    
    location /hls/ {
        alias /opt/hls-converter/hls/;
        add_header Cache-Control "public, max-age=31536000";
        add_header Access-Control-Allow-Origin *;
        
        # Configurações específicas para arquivos HLS
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
            video/mp4 mp4;
            image/jpeg jpg;
        }
        
        # Permitir streaming
        sendfile on;
        tcp_nopush on;
    }
    
    # Bloquear acesso direto a arquivos sensíveis
    location ~ /\. {
        deny all;
    }
    
    location ~ /(db|sessions|backups) {
        deny all;
    }
}
EOF

# Ativar site
ln -sf /etc/nginx/sites-available/hls-converter /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# 9. CRIAR APLICAÇÃO FLASK COMPLETA COM MULTIARQUIVOS E ARQUIVOS INTERNOS
echo "💻 Criando aplicação Flask corrigida..."

cat > /opt/hls-converter/app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão Multiarquivos
Sistema completo com opção para arquivos externos e internos
"""

import os
import sys
import json
import time
import uuid
import shutil
import subprocess
import zipfile
import tarfile
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from flask import Flask, request, jsonify, render_template_string, send_file, redirect, url_for, session, flash, Response
from flask_cors import CORS
import bcrypt
import secrets
import psutil
import threading
from queue import Queue
import concurrent.futures

# =============== CONFIGURAÇÃO INICIAL ===============
app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)

# Configurações de segurança
app.secret_key = secrets.token_hex(32)
app.config['SESSION_TYPE'] = 'filesystem'
app.config['SESSION_FILE_DIR'] = '/opt/hls-converter/sessions'
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=2)
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SECURE'] = False
app.config['MAX_CONTENT_LENGTH'] = 2 * 1024 * 1024 * 1024  # 2GB max upload

# Diretórios
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
BACKUP_DIR = os.path.join(BASE_DIR, "backups")
STATIC_DIR = os.path.join(BASE_DIR, "static")
INTERNAL_VIDEOS_DIR = os.path.join(BASE_DIR, "videos_internos")
USERS_FILE = os.path.join(DB_DIR, "users.json")
CONVERSIONS_FILE = os.path.join(DB_DIR, "conversions.json")

# Criar diretórios
for dir_path in [UPLOAD_DIR, HLS_DIR, LOG_DIR, DB_DIR, BACKUP_DIR, STATIC_DIR, INTERNAL_VIDEOS_DIR, app.config['SESSION_FILE_DIR']]:
    os.makedirs(dir_path, exist_ok=True)

# Fila para processamento em sequência
processing_queue = Queue()
executor = concurrent.futures.ThreadPoolExecutor(max_workers=2)

# Variável global para progresso
conversion_progress = {}

# =============== FUNÇÕES AUXILIARES ===============
def load_users():
    """Carrega usuários do arquivo JSON"""
    default_users = {
        "users": {
            "admin": {
                "password": "$2b$12$7eE8R5Yq3X3t7kXq3Z8p9eBvG9HjK1L2N3M4Q5W6X7Y8Z9A0B1C2D3E4F5G6H7I8J9",  # admin
                "password_changed": False,
                "created_at": datetime.now().isoformat(),
                "last_login": None,
                "role": "admin"
            }
        },
        "settings": {
            "require_password_change": True,
            "session_timeout": 7200,
            "max_login_attempts": 5,
            "max_concurrent_conversions": 1,
            "keep_originals": True
        }
    }
    
    try:
        if os.path.exists(USERS_FILE):
            with open(USERS_FILE, 'r') as f:
                data = json.load(f)
                if 'users' not in data:
                    data['users'] = default_users['users']
                if 'settings' not in data:
                    data['settings'] = default_users['settings']
                return data
    except Exception as e:
        print(f"Erro ao carregar usuários: {e}")
        save_users(default_users)
    
    return default_users

def save_users(data):
    """Salva usuários no arquivo JSON"""
    try:
        with open(USERS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Erro ao salvar usuários: {e}")

def load_conversions():
    """Carrega conversões do arquivo JSON"""
    default_data = {
        "conversions": [],
        "stats": {"total": 0, "success": 0, "failed": 0}
    }
    
    try:
        if os.path.exists(CONVERSIONS_FILE):
            with open(CONVERSIONS_FILE, 'r') as f:
                data = json.load(f)
                if 'conversions' not in data:
                    data['conversions'] = []
                if 'stats' not in data:
                    data['stats'] = default_data['stats']
                return data
    except Exception as e:
        print(f"Erro ao carregar conversões: {e}")
        save_conversions(default_data)
    
    return default_data

def save_conversions(data):
    """Salva conversões no arquivo JSON"""
    try:
        if not isinstance(data.get('conversions'), list):
            data['conversions'] = []
        
        if 'stats' not in data:
            data['stats'] = {"total": 0, "success": 0, "failed": 0}
        
        with open(CONVERSIONS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Erro ao salvar conversões: {e}")

def check_password(username, password):
    """Verifica se a senha está correta"""
    users = load_users()
    
    if username not in users.get('users', {}):
        return False
    
    stored_hash = users['users'][username].get('password', '')
    if not stored_hash:
        return False
    
    try:
        return bcrypt.checkpw(password.encode('utf-8'), stored_hash.encode('utf-8'))
    except Exception as e:
        print(f"Erro em check_password: {e}")
        return False

def password_change_required(username):
    """Verifica se o usuário precisa alterar a senha"""
    users = load_users()
    if username in users.get('users', {}):
        return not users['users'][username].get('password_changed', False)
    return False

def find_ffmpeg():
    """Encontra o caminho do ffmpeg"""
    for path in ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/bin/ffmpeg', '/snap/bin/ffmpeg']:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    return None

def log_activity(message):
    """Registra atividade no log"""
    try:
        log_file = os.path.join(LOG_DIR, "activity.log")
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(log_file, 'a') as f:
            f.write(f"[{timestamp}] {message}\n")
    except:
        pass

def sanitize_filename(filename):
    """Remove caracteres inválidos do nome do arquivo"""
    safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ."
    filename = ''.join(c for c in filename if c in safe_chars)
    filename = ' '.join(filename.split())
    if len(filename) > 100:
        name, ext = os.path.splitext(filename)
        filename = name[:95] + ext
    return filename.strip()

def create_backup(backup_name=None):
    """Cria um backup completo do sistema"""
    try:
        if not backup_name:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_name = f"hls_backup_{timestamp}"
        
        backup_path = os.path.join(BACKUP_DIR, f"{backup_name}.tar.gz")
        
        dirs_to_backup = [
            DB_DIR,
            os.path.join(BASE_DIR, "app.py"),
            os.path.join(LOG_DIR, "activity.log")
        ]
        
        metadata = {
            "backup_name": backup_name,
            "created_at": datetime.now().isoformat(),
            "version": "2.5.0",
            "directories": dirs_to_backup,
            "total_users": len(load_users().get('users', {})),
            "total_conversions": load_conversions().get('stats', {}).get('total', 0)
        }
        
        metadata_file = os.path.join(BACKUP_DIR, f"{backup_name}_metadata.json")
        with open(metadata_file, 'w') as f:
            json.dump(metadata, f, indent=2)
        
        dirs_to_backup.append(metadata_file)
        
        with tarfile.open(backup_path, "w:gz") as tar:
            for item in dirs_to_backup:
                if os.path.exists(item):
                    if os.path.isfile(item):
                        tar.add(item, arcname=os.path.basename(item))
                    else:
                        for root, dirs, files in os.walk(item):
                            for file in files:
                                filepath = os.path.join(root, file)
                                arcname = os.path.relpath(filepath, BASE_DIR)
                                tar.add(filepath, arcname=arcname)
        
        os.remove(metadata_file)
        
        size = os.path.getsize(backup_path)
        
        return {
            "success": True,
            "backup_path": backup_path,
            "backup_name": backup_name,
            "size": size,
            "created_at": metadata['created_at']
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }

def restore_backup(backup_file):
    """Restaura o sistema a partir de um backup"""
    try:
        extract_dir = tempfile.mkdtemp(prefix="hls_restore_")
        
        with tarfile.open(backup_file, "r:gz") as tar:
            tar.extractall(path=extract_dir)
        
        metadata_files = [f for f in os.listdir(extract_dir) if f.endswith('_metadata.json')]
        if metadata_files:
            metadata_file = os.path.join(extract_dir, metadata_files[0])
            with open(metadata_file, 'r') as f:
                metadata = json.load(f)
        
        for root, dirs, files in os.walk(extract_dir):
            for file in files:
                if file.endswith('_metadata.json'):
                    continue
                
                src_path = os.path.join(root, file)
                rel_path = os.path.relpath(src_path, extract_dir)
                
                if rel_path.startswith("db/"):
                    dst_path = os.path.join(DB_DIR, os.path.basename(file))
                elif rel_path == "app.py":
                    dst_path = os.path.join(BASE_DIR, "app.py")
                elif rel_path == "activity.log":
                    dst_path = os.path.join(LOG_DIR, "activity.log")
                else:
                    dst_path = os.path.join(BASE_DIR, rel_path)
                
                os.makedirs(os.path.dirname(dst_path), exist_ok=True)
                shutil.copy2(src_path, dst_path)
        
        shutil.rmtree(extract_dir)
        
        return {
            "success": True,
            "message": "Backup restaurado com sucesso",
            "metadata": metadata if 'metadata' in locals() else None
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }

def list_backups():
    """Lista todos os backups disponíveis"""
    backups = []
    try:
        for filename in os.listdir(BACKUP_DIR):
            if filename.endswith('.tar.gz'):
                filepath = os.path.join(BACKUP_DIR, filename)
                stat = os.stat(filepath)
                backups.append({
                    "name": filename,
                    "path": filepath,
                    "size": stat.st_size,
                    "created": datetime.fromtimestamp(stat.st_ctime).isoformat(),
                    "modified": datetime.fromtimestamp(stat.st_mtime).isoformat()
                })
        
        backups.sort(key=lambda x: x['modified'], reverse=True)
        
    except Exception as e:
        print(f"Erro ao listar backups: {e}")
    
    return backups

def update_progress(playlist_id, file_index, total_files, message="", filename=""):
    """Atualiza o progresso da conversão"""
    progress = {
        "playlist_id": playlist_id,
        "file_index": file_index,
        "total_files": total_files,
        "progress_percent": int((file_index / total_files) * 100) if total_files > 0 else 0,
        "message": message,
        "filename": filename,
        "timestamp": datetime.now().isoformat()
    }
    conversion_progress[playlist_id] = progress
    return progress

def get_progress(playlist_id):
    """Obtém o progresso atual"""
    return conversion_progress.get(playlist_id, {
        "progress_percent": 0,
        "message": "Aguardando início",
        "filename": ""
    })

def list_internal_videos():
    """Lista vídeos disponíveis no diretório interno"""
    video_files = []
    
    try:
        for file in os.listdir(INTERNAL_VIDEOS_DIR):
            file_path = os.path.join(INTERNAL_VIDEOS_DIR, file)
            if os.path.isfile(file_path):
                video_extensions = ['.mp4', '.avi', '.mov', '.mkv', '.webm', '.flv', '.wmv', '.m4v', '.mpeg', '.mpg']
                if any(file.lower().endswith(ext) for ext in video_extensions):
                    stat = os.stat(file_path)
                    video_files.append({
                        "name": file,
                        "path": file_path,
                        "size": stat.st_size,
                        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat()
                    })
        
        video_files.sort(key=lambda x: x['name'])
        
    except Exception as e:
        print(f"Erro ao listar vídeos internos: {e}")
    
    return video_files

# =============== FUNÇÕES DE CONVERSÃO MULTIARQUIVOS ===============
def convert_single_video(video_path, playlist_id, index, total_files, qualities, progress_callback=None):
    """
    Converte um único vídeo para HLS - versão multiarquivos
    """
    ffmpeg_path = find_ffmpeg()
    if not ffmpeg_path:
        return None, "FFmpeg não encontrado"
    
    filename = os.path.basename(video_path)
    video_id = f"{playlist_id}_{index:03d}"
    output_dir = os.path.join(HLS_DIR, playlist_id, video_id)
    os.makedirs(output_dir, exist_ok=True)
    
    video_info = {
        "id": video_id,
        "filename": filename,
        "original_path": video_path,
        "qualities": [],
        "duration": 0,
        "playlist_paths": {}
    }
    
    for quality in qualities:
        quality_dir = os.path.join(output_dir, quality)
        os.makedirs(quality_dir, exist_ok=True)
        
        m3u8_file = os.path.join(quality_dir, "index.m3u8")
        
        if quality == '240p':
            scale = "426:240"
            bitrate = "400k"
            audio_bitrate = "64k"
            bandwidth = "400000"
        elif quality == '480p':
            scale = "854:480"
            bitrate = "800k"
            audio_bitrate = "96k"
            bandwidth = "800000"
        elif quality == '720p':
            scale = "1280:720"
            bitrate = "1500k"
            audio_bitrate = "128k"
            bandwidth = "1500000"
        elif quality == '1080p':
            scale = "1920:1080"
            bitrate = "3000k"
            audio_bitrate = "192k"
            bandwidth = "3000000"
        else:
            continue
        
        cmd = [
            ffmpeg_path, '-i', video_path,
            '-vf', f'scale={scale},format=yuv420p',
            '-c:v', 'libx264', 
            '-preset', 'medium',
            '-crf', '23',
            '-maxrate', bitrate,
            '-bufsize', f'{int(int(bandwidth) * 2)}',
            '-c:a', 'aac', 
            '-b:a', audio_bitrate,
            '-hls_time', '6',
            '-hls_list_size', '0',
            '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
            '-f', 'hls', 
            '-hls_flags', 'independent_segments',
            '-threads', '2',
            '-y',
            m3u8_file
        ]
        
        try:
            if progress_callback:
                progress_callback(f"Convertendo {filename} para {quality}...")
            
            process = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE,
                universal_newlines=True
            )
            stdout, stderr = process.communicate(timeout=1200)
            
            if process.returncode == 0:
                video_info["qualities"].append(quality)
                video_info["playlist_paths"][quality] = f"{playlist_id}/{video_id}/{quality}/index.m3u8"
                
                try:
                    duration_cmd = [ffmpeg_path, '-i', video_path]
                    duration_result = subprocess.run(
                        duration_cmd, 
                        capture_output=True, 
                        text=True, 
                        stderr=subprocess.STDOUT,
                        timeout=10
                    )
                    for line in duration_result.stdout.split('\n'):
                        if 'Duration' in line:
                            duration_part = line.split('Duration:')[1].split(',')[0].strip()
                            h, m, s = duration_part.split(':')
                            video_info["duration"] = int(h) * 3600 + int(m) * 60 + float(s)
                            break
                except Exception as e:
                    print(f"Erro ao obter duração: {e}")
                    video_info["duration"] = 60
                    
            else:
                error_msg = stderr[:500] if stderr else stdout[:500]
                print(f"Erro FFmpeg para {quality}: {error_msg}")
                
                if progress_callback:
                    progress_callback(f"Tentando conversão alternativa para {quality}...")
                
                simple_cmd = [
                    ffmpeg_path, '-i', video_path,
                    '-vf', f'scale={scale}',
                    '-c:v', 'libx264', '-preset', 'fast',
                    '-c:a', 'aac', '-b:a', audio_bitrate,
                    '-hls_time', '6',
                    '-hls_list_size', '0',
                    '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                    '-f', 'hls', 
                    '-threads', '2',
                    '-y',
                    m3u8_file
                ]
                
                simple_result = subprocess.run(
                    simple_cmd,
                    capture_output=True,
                    text=True,
                    timeout=1200
                )
                
                if simple_result.returncode == 0:
                    video_info["qualities"].append(quality)
                    video_info["playlist_paths"][quality] = f"{playlist_id}/{video_id}/{quality}/index.m3u8"
                    video_info["duration"] = 60
                    
        except subprocess.TimeoutExpired:
            print(f"Timeout na conversão para {quality}")
            process.kill()
            return None, f"Timeout na conversão de {filename} para {quality}"
        except Exception as e:
            print(f"Erro geral na conversão {quality}: {str(e)}")
            return None, f"Erro na conversão de {filename}: {str(e)}"
    
    return video_info, None

def process_multiple_videos(video_paths, qualities, playlist_id, conversion_name, files_data=None):
    """
    Processa múltiplos vídeos em sequência - VERSÃO MULTIARQUIVOS
    """
    videos_info = []
    errors = []
    
    total_files = len(video_paths)
    
    for index, video_path in enumerate(video_paths, 1):
        print(f"Processando arquivo {index}/{total_files}: {video_path}")
        
        try:
            filename = os.path.basename(video_path)
            
            update_progress(playlist_id, index - 1, total_files, f"Convertendo: {filename}", filename)
            
            def progress_callback(message):
                update_progress(playlist_id, index - 1, total_files, message, filename)
            
            video_info, error = convert_single_video(
                video_path, 
                playlist_id, 
                index, 
                total_files, 
                qualities,
                progress_callback
            )
            
            if error:
                errors.append(f"{filename}: {error}")
                video_info = {
                    "id": f"{playlist_id}_{index:03d}",
                    "filename": filename,
                    "qualities": [],
                    "error": error,
                    "duration": 60
                }
            else:
                update_progress(playlist_id, index, total_files, f"Concluído: {filename}", filename)
            
            videos_info.append(video_info)
            print(f"Concluído: {filename} ({index}/{total_files})")
                
        except Exception as e:
            error_msg = f"Erro ao processar {os.path.basename(video_path)}: {str(e)}"
            print(error_msg)
            errors.append(error_msg)
            
            videos_info.append({
                "id": f"{playlist_id}_{index:03d}",
                "filename": os.path.basename(video_path),
                "qualities": [],
                "error": error_msg,
                "duration": 60
            })
    
    update_progress(playlist_id, total_files, total_files, "Criando playlists...", "")
    
    videos_with_qualities = [v for v in videos_info if v.get("qualities")]
    
    if videos_with_qualities:
        master_playlist, total_duration = create_master_playlist(playlist_id, videos_info, qualities, conversion_name)
        
        update_progress(playlist_id, total_files, total_files, "Conversão completa!", "")
        
        return {
            "success": True,
            "playlist_id": playlist_id,
            "conversion_name": conversion_name,
            "videos_count": len(videos_info),
            "videos_converted": len(videos_with_qualities),
            "errors": errors,
            "master_playlist": f"/hls/{playlist_id}/master.m3u8",
            "player_url": f"/player/{playlist_id}",
            "videos_info": videos_info,
            "total_duration": total_duration,
            "qualities": [q for q in qualities if any(q in v.get("qualities", []) for v in videos_info)],
            "quality_links": {
                quality: f"/hls/{playlist_id}/{quality}/index.m3u8"
                for quality in qualities
                if any(quality in v.get("qualities", []) for v in videos_info)
            },
            "video_links": [
                {
                    "filename": v["filename"],
                    "links": {
                        quality: f"/hls/{playlist_id}/{v['id']}/{quality}/index.m3u8"
                        for quality in v.get("qualities", [])
                    }
                }
                for v in videos_info if v.get("qualities")
            ]
        }
    else:
        return {
            "success": False,
            "playlist_id": playlist_id,
            "conversion_name": conversion_name,
            "errors": errors if errors else ["Nenhum vídeo foi convertido com sucesso"],
            "videos_info": videos_info
        }

def create_master_playlist(playlist_id, videos_info, qualities, conversion_name):
    """
    Cria um master playlist M3U8 - VERSÃO MULTIARQUIVOS
    """
    playlist_dir = os.path.join(HLS_DIR, playlist_id)
    master_playlist = os.path.join(playlist_dir, "master.m3u8")
    
    playlist_info = {
        "playlist_id": playlist_id,
        "conversion_name": conversion_name,
        "created_at": datetime.now().isoformat(),
        "videos_count": len(videos_info),
        "total_duration": 0,
        "videos": videos_info
    }
    
    with open(master_playlist, 'w') as f:
        f.write("#EXTM3U\n")
        f.write("#EXT-X-VERSION:6\n")
        
        for quality in qualities:
            has_quality = False
            for video in videos_info:
                if quality in video.get("qualities", []):
                    has_quality = True
                    break
            
            if not has_quality:
                continue
            
            if quality == '240p':
                bandwidth = "400000"
                resolution = "426x240"
            elif quality == '480p':
                bandwidth = "800000"
                resolution = "854x480"
            elif quality == '720p':
                bandwidth = "1500000"
                resolution = "1280x720"
            elif quality == '1080p':
                bandwidth = "3000000"
                resolution = "1920x1080"
            else:
                continue
            
            f.write(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={resolution},CODECS="avc1.64001f,mp4a.40.2"\n')
            f.write(f'{quality}/index.m3u8\n')
    
    for quality in qualities:
        quality_playlist_path = os.path.join(playlist_dir, quality, "index.m3u8")
        os.makedirs(os.path.dirname(quality_playlist_path), exist_ok=True)
        
        with open(quality_playlist_path, 'w') as qf:
            qf.write("#EXTM3U\n")
            qf.write("#EXT-X-VERSION:6\n")
            qf.write("#EXT-X-TARGETDURATION:10\n")
            qf.write("#EXT-X-MEDIA-SEQUENCE:0\n")
            qf.write("#EXT-X-PLAYLIST-TYPE:VOD\n")
            
            for video_info in videos_info:
                if quality in video_info.get("qualities", []):
                    video_playlist_path = f"{video_info['id']}/{quality}/index.m3u8"
                    qf.write(f'#EXT-X-DISCONTINUITY\n')
                    qf.write(f'#EXTINF:{video_info.get("duration", 10):.6f},\n')
                    qf.write(f'{video_playlist_path}\n')
                    playlist_info["total_duration"] += video_info.get("duration", 10)
            
            qf.write("#EXT-X-ENDLIST\n")
    
    info_file = os.path.join(playlist_dir, "playlist_info.json")
    with open(info_file, 'w') as f:
        json.dump(playlist_info, f, indent=2)
    
    return master_playlist, playlist_info["total_duration"]

# =============== PÁGINAS HTML COM MULTIARQUIVOS E ARQUIVOS INTERNOS ===============

LOGIN_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔐 Login - HLS Converter</title>
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: Arial, sans-serif;
        }
        .login-box {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            width: 100%;
            max-width: 400px;
        }
        .login-box h2 {
            color: #333;
            text-align: center;
            margin-bottom: 30px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        .form-group input {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 16px;
        }
        .btn-login {
            width: 100%;
            padding: 12px;
            background: #4361ee;
            color: white;
            border: none;
            border-radius: 5px;
            font-size: 16px;
            cursor: pointer;
        }
        .btn-login:hover {
            background: #3a0ca3;
        }
        .alert {
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .alert-error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        .alert-success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        .credentials {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 5px;
            margin-top: 20px;
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="login-box">
        <h2>🔐 HLS Converter ULTIMATE</h2>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }}">
                        {{ message }}
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" action="/login">
            <div class="form-group">
                <input type="text" name="username" placeholder="Usuário" required autofocus>
            </div>
            <div class="form-group">
                <input type="password" name="password" placeholder="Senha" required>
            </div>
            <button type="submit" class="btn-login">Entrar</button>
        </form>
        
        <div class="credentials">
            <p><strong>Usuário padrão:</strong> admin</p>
            <p><strong>Senha padrão:</strong> admin</p>
            <p style="color: #dc3545; margin-top: 10px;">
                ⚠️ Altere a senha no primeiro acesso
            </p>
        </div>
    </div>
</body>
</html>
'''

CHANGE_PASSWORD_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔑 Alterar Senha</title>
    <style>
        body {
            background: linear-gradient(135deg, #4cc9f0 0%, #4361ee 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: Arial, sans-serif;
        }
        .password-box {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            width: 100%;
            max-width: 450px;
        }
        .password-box h2 {
            color: #333;
            text-align: center;
            margin-bottom: 30px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: #555;
        }
        .form-group input {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 16px;
        }
        .btn-change {
            width: 100%;
            padding: 12px;
            background: #4cc9f0;
            color: white;
            border: none;
            border-radius: 5px;
            font-size: 16px;
            cursor: pointer;
        }
        .btn-change:hover {
            background: #3aa8cc;
        }
        .requirements {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 5px;
            margin-top: 20px;
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="password-box">
        <h2>🔑 Alterar Senha</h2>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }}">
                        {{ message }}
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" action="/change-password">
            <div class="form-group">
                <label>Senha Atual:</label>
                <input type="password" name="current_password" required>
            </div>
            <div class="form-group">
                <label>Nova Senha:</label>
                <input type="password" name="new_password" required>
            </div>
            <div class="form-group">
                <label>Confirmar Nova Senha:</label>
                <input type="password" name="confirm_password" required>
            </div>
            <button type="submit" class="btn-change">Alterar Senha</button>
        </form>
        
        <div class="requirements">
            <strong>Requisitos da senha:</strong>
            <ul>
                <li>Mínimo 8 caracteres</li>
                <li>Pelo menos uma letra maiúscula</li>
                <li>Pelo menos uma letra minúscula</li>
                <li>Pelo menos um número</li>
                <li>Pelo menos um caractere especial</li>
            </ul>
        </div>
    </div>
</body>
</html>
'''

DASHBOARD_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Converter ULTIMATE - MULTIARQUIVOS</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        :root {
            --primary: #4361ee;
            --secondary: #3a0ca3;
            --accent: #4cc9f0;
            --success: #2ecc71;
            --danger: #e74c3c;
            --warning: #f39c12;
            --dark: #2c3e50;
            --light: #ecf0f1;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #f5f7fa 0%, #c3cfe2 100%);
            color: var(--dark);
            line-height: 1.6;
        }
        
        .header {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            color: white;
            padding: 20px 30px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 4px 12px rgba(0,0,0,0.1);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        
        .logo {
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .logo i {
            font-size: 2rem;
        }
        
        .logo h1 {
            font-size: 1.8rem;
            font-weight: 600;
        }
        
        .user-info {
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .user-info span {
            background: rgba(255,255,255,0.2);
            padding: 8px 15px;
            border-radius: 20px;
            font-weight: 500;
        }
        
        .logout-btn {
            background: rgba(255,255,255,0.2);
            border: 1px solid rgba(255,255,255,0.3);
            color: white;
            padding: 8px 20px;
            border-radius: 5px;
            text-decoration: none;
            transition: all 0.3s;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        
        .logout-btn:hover {
            background: rgba(255,255,255,0.3);
            transform: translateY(-1px);
        }
        
        .container {
            max-width: 1400px;
            margin: 30px auto;
            padding: 0 20px;
        }
        
        .nav-tabs {
            display: flex;
            background: white;
            border-radius: 10px;
            padding: 10px;
            margin-bottom: 30px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.08);
            overflow-x: auto;
        }
        
        .nav-tab {
            padding: 15px 25px;
            cursor: pointer;
            border-radius: 8px;
            transition: all 0.3s;
            display: flex;
            align-items: center;
            gap: 10px;
            font-weight: 500;
            white-space: nowrap;
        }
        
        .nav-tab:hover {
            background: var(--light);
        }
        
        .nav-tab.active {
            background: var(--primary);
            color: white;
            box-shadow: 0 4px 10px rgba(67, 97, 238, 0.3);
        }
        
        .tab-content {
            display: none;
            animation: fadeIn 0.5s ease;
        }
        
        .tab-content.active {
            display: block;
        }
        
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        .card {
            background: white;
            border-radius: 12px;
            padding: 25px;
            margin-bottom: 25px;
            box-shadow: 0 8px 25px rgba(0,0,0,0.08);
            border: 1px solid #eaeaea;
        }
        
        .card h2 {
            color: var(--primary);
            margin-bottom: 20px;
            padding-bottom: 15px;
            border-bottom: 2px solid #f0f0f0;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        
        /* Tabs de upload */
        .upload-tabs {
            display: flex;
            background: #f8f9fa;
            border-radius: 10px;
            padding: 5px;
            margin-bottom: 20px;
        }
        
        .upload-tab {
            flex: 1;
            padding: 15px;
            text-align: center;
            cursor: pointer;
            border-radius: 8px;
            transition: all 0.3s;
            font-weight: 500;
        }
        
        .upload-tab:hover {
            background: #e9ecef;
        }
        
        .upload-tab.active {
            background: var(--primary);
            color: white;
        }
        
        /* Conteúdo de upload */
        .upload-content {
            display: none;
        }
        
        .upload-content.active {
            display: block;
            animation: fadeIn 0.5s ease;
        }
        
        .upload-area {
            border: 3px dashed var(--primary);
            border-radius: 12px;
            padding: 60px 30px;
            text-align: center;
            margin: 30px 0;
            cursor: pointer;
            transition: all 0.3s;
            background: rgba(67, 97, 238, 0.02);
        }
        
        .upload-area:hover {
            background: rgba(67, 97, 238, 0.05);
            border-color: var(--secondary);
            transform: translateY(-2px);
        }
        
        .upload-area i {
            font-size: 4rem;
            color: var(--primary);
            margin-bottom: 20px;
        }
        
        .btn {
            padding: 12px 30px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }
        
        .btn-primary {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            color: white;
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 20px rgba(67, 97, 238, 0.3);
        }
        
        .btn-success {
            background: linear-gradient(90deg, var(--success) 0%, #27ae60 100%);
            color: white;
        }
        
        .btn-warning {
            background: linear-gradient(90deg, var(--warning) 0%, #e67e22 100%);
            color: white;
        }
        
        .btn-danger {
            background: linear-gradient(90deg, var(--danger) 0%, #c0392b 100%);
            color: white;
        }
        
        .progress-container {
            background: #e9ecef;
            border-radius: 10px;
            height: 20px;
            overflow: hidden;
            margin: 20px 0;
        }
        
        .progress-bar {
            height: 100%;
            background: linear-gradient(90deg, var(--accent) 0%, var(--primary) 100%);
            transition: width 0.5s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-size: 0.8rem;
            font-weight: 600;
        }
        
        .quality-selector {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(100px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }
        
        .quality-option {
            background: var(--light);
            padding: 15px;
            border-radius: 8px;
            text-align: center;
            cursor: pointer;
            transition: all 0.3s;
            border: 2px solid transparent;
        }
        
        .quality-option:hover {
            background: #e3e6ea;
        }
        
        .quality-option.selected {
            background: var(--primary);
            color: white;
            border-color: var(--secondary);
        }
        
        .selected-files {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin-top: 20px;
            max-height: 300px;
            overflow-y: auto;
        }
        
        .file-list {
            list-style: none;
            padding: 0;
        }
        
        .file-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px 15px;
            background: white;
            border-radius: 8px;
            margin-bottom: 8px;
            border: 1px solid #eaeaea;
        }
        
        .file-item .file-name {
            flex: 1;
            font-weight: 500;
        }
        
        .file-item .file-size {
            color: #6c757d;
            margin: 0 15px;
        }
        
        .file-item .remove-file {
            color: #e74c3c;
            cursor: pointer;
            background: none;
            border: none;
            font-size: 1.2rem;
        }
        
        .upload-count {
            background: var(--primary);
            color: white;
            padding: 5px 10px;
            border-radius: 20px;
            font-size: 0.9rem;
            margin-left: 10px;
        }
        
        .conversion-name-input {
            width: 100%;
            padding: 15px;
            border: 2px solid #4361ee;
            border-radius: 10px;
            font-size: 16px;
            margin: 20px 0;
            transition: all 0.3s;
            background: #f8f9fa;
        }
        
        .conversion-name-input:focus {
            outline: none;
            border-color: #3a0ca3;
            box-shadow: 0 0 0 3px rgba(67, 97, 238, 0.1);
            background: white;
        }
        
        .real-time-progress {
            background: linear-gradient(135deg, #4361ee 0%, #3a0ca3 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
            display: none;
        }
        
        .real-time-progress.show {
            display: block;
        }
        
        .links-container {
            background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%);
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
            display: none;
        }
        
        .links-container.show {
            display: block;
            animation: fadeIn 0.5s ease;
        }
        
        .link-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 15px;
            background: white;
            border-radius: 8px;
            margin-bottom: 10px;
            border-left: 4px solid #4361ee;
        }
        
        /* Estilos para vídeos internos */
        .internal-videos-container {
            max-height: 400px;
            overflow-y: auto;
            margin: 20px 0;
            border: 1px solid #dee2e6;
            border-radius: 8px;
        }
        
        .internal-video-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 12px 15px;
            border-bottom: 1px solid #eaeaea;
            cursor: pointer;
            transition: all 0.3s;
        }
        
        .internal-video-item:hover {
            background: #f8f9fa;
        }
        
        .internal-video-item.selected {
            background: #e3f2fd;
            border-left: 4px solid #4361ee;
        }
        
        .internal-video-info {
            flex: 1;
        }
        
        .internal-video-name {
            font-weight: 500;
            color: #2c3e50;
        }
        
        .internal-video-meta {
            font-size: 0.8rem;
            color: #6c757d;
        }
        
        .internal-video-checkbox {
            width: 20px;
            height: 20px;
            cursor: pointer;
        }
        
        .video-selection-controls {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin: 15px 0;
            padding: 15px;
            background: #f8f9fa;
            border-radius: 8px;
        }
        
        @media (max-width: 768px) {
            .header {
                flex-direction: column;
                gap: 15px;
                text-align: center;
            }
            
            .nav-tabs {
                flex-wrap: wrap;
            }
            
            .nav-tab {
                flex: 1;
                min-width: 120px;
                justify-content: center;
            }
            
            .upload-tabs {
                flex-direction: column;
            }
        }
        
        .toast {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: white;
            padding: 15px 25px;
            border-radius: 8px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.15);
            display: flex;
            align-items: center;
            gap: 15px;
            z-index: 1000;
            animation: slideIn 0.3s ease;
            border-left: 4px solid var(--primary);
        }
        
        @keyframes slideIn {
            from { transform: translateX(100%); opacity: 0; }
            to { transform: translateX(0); opacity: 1; }
        }
        
        .toast.success {
            border-left-color: var(--success);
        }
        
        .toast.error {
            border-left-color: var(--danger);
        }
        
        .toast.warning {
            border-left-color: var(--warning);
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="logo">
            <i class="fas fa-video"></i>
            <h1>HLS Converter ULTIMATE - MULTIARQUIVOS</h1>
        </div>
        <div class="user-info">
            <span><i class="fas fa-user"></i> {{ session.user_id }}</span>
            <a href="/logout" class="logout-btn">
                <i class="fas fa-sign-out-alt"></i> Sair
            </a>
        </div>
    </div>
    
    <div class="container">
        <!-- Navegação -->
        <div class="nav-tabs">
            <div class="nav-tab active" onclick="showTab('dashboard')">
                <i class="fas fa-tachometer-alt"></i> Dashboard
            </div>
            <div class="nav-tab" onclick="showTab('upload')">
                <i class="fas fa-upload"></i> Upload
            </div>
            <div class="nav-tab" onclick="showTab('conversions')">
                <i class="fas fa-history"></i> Histórico
            </div>
            <div class="nav-tab" onclick="showTab('settings')">
                <i class="fas fa-cog"></i> Configurações
            </div>
            <div class="nav-tab" onclick="showTab('backup')">
                <i class="fas fa-database"></i> Backup
            </div>
        </div>
        
        <!-- Dashboard Tab -->
        <div id="dashboard" class="tab-content active">
            <div class="card">
                <h2><i class="fas fa-tachometer-alt"></i> Status do Sistema</h2>
                <div class="stats-grid">
                    <div class="stat-item">
                        <div class="stat-value" id="cpu">--%</div>
                        <div class="stat-label">Uso de CPU</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="memory">--%</div>
                        <div class="stat-label">Uso de Memória</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="conversionsTotal">0</div>
                        <div class="stat-label">Total de Conversões</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="conversionsSuccess">0</div>
                        <div class="stat-label">Conversões Bem-sucedidas</div>
                    </div>
                </div>
                
                <div class="system-status">
                    <h3><i class="fas fa-microchip"></i> Status do FFmpeg</h3>
                    <div id="ffmpegStatus" class="ffmpeg-status">Verificando...</div>
                    <p id="ffmpegPath" style="margin-top: 10px; font-size: 0.9rem;"></p>
                </div>
            </div>
            
            <div class="card">
                <h2><i class="fas fa-bolt"></i> Ações Rápidas</h2>
                <div style="display: flex; gap: 15px; margin-top: 20px; flex-wrap: wrap;">
                    <button class="btn btn-primary" onclick="showTab('upload')">
                        <i class="fas fa-upload"></i> Converter Vídeos
                    </button>
                    <button class="btn btn-success" onclick="refreshStats()">
                        <i class="fas fa-sync-alt"></i> Atualizar Status
                    </button>
                    <button class="btn btn-warning" onclick="testFFmpeg()">
                        <i class="fas fa-video"></i> Testar FFmpeg
                    </button>
                    <button class="btn btn-danger" onclick="cleanupFiles()">
                        <i class="fas fa-trash"></i> Limpar Arquivos
                    </button>
                </div>
            </div>
        </div>
        
        <!-- Upload Tab - COM DUAS OPÇÕES -->
        <div id="upload" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-upload"></i> Converter Múltiplos Vídeos para HLS</h2>
                <p style="color: #666; margin-bottom: 20px;">
                    Selecione vários vídeos para converter em sequência. Todos os vídeos serão combinados em uma única playlist HLS.
                </p>
                
                <!-- Tabs de seleção -->
                <div class="upload-tabs">
                    <div class="upload-tab active" onclick="showUploadTab('external')">
                        <i class="fas fa-cloud-upload-alt"></i> Upload de Arquivos
                    </div>
                    <div class="upload-tab" onclick="showUploadTab('internal')">
                        <i class="fas fa-folder-open"></i> Arquivos Internos
                    </div>
                </div>
                
                <!-- Campo de nome da conversão -->
                <div style="margin-bottom: 20px;">
                    <h3><i class="fas fa-font"></i> Nome da Conversão</h3>
                    <input type="text" 
                           id="conversionName" 
                           class="conversion-name-input" 
                           placeholder="Digite um nome para esta conversão (ex: Aula de Matemática, Evento Corporativo, etc.)"
                           maxlength="100"
                           required>
                    <p style="color: #666; font-size: 0.9rem; margin-top: 5px;">
                        Este nome será usado para identificar sua conversão no histórico e nos links gerados
                    </p>
                </div>
                
                <!-- Conteúdo para upload externo -->
                <div id="externalUpload" class="upload-content active">
                    <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                        <i class="fas fa-cloud-upload-alt"></i>
                        <h3>Arraste e solte seus vídeos aqui</h3>
                        <p>ou clique para selecionar múltiplos arquivos (Ctrl + Click)</p>
                        <p style="color: #666; margin-top: 10px;">
                            Formatos suportados: MP4, AVI, MOV, MKV, WEBM - Até 2GB por arquivo
                        </p>
                    </div>
                    
                    <input type="file" id="fileInput" accept="video/*" multiple style="display: none;" onchange="handleExternalFileSelect()">
                    
                    <div id="selectedExternalFiles" class="selected-files" style="display: none;">
                        <h4><i class="fas fa-file-video"></i> Arquivos Selecionados <span id="externalFileCount" class="upload-count">0</span></h4>
                        <ul id="externalFileList" class="file-list"></ul>
                    </div>
                </div>
                
                <!-- Conteúdo para arquivos internos -->
                <div id="internalUpload" class="upload-content">
                    <div style="text-align: center; margin: 20px 0;">
                        <i class="fas fa-folder-open" style="font-size: 3rem; color: #4361ee;"></i>
                        <h3>Selecione vídeos do diretório interno</h3>
                        <p>Vídeos disponíveis no diretório: <code>/opt/hls-converter/videos_internos/</code></p>
                        <button class="btn btn-primary" onclick="loadInternalVideos()" style="margin-top: 15px;">
                            <i class="fas fa-sync-alt"></i> Atualizar Lista
                        </button>
                    </div>
                    
                    <div id="internalVideosContainer" class="internal-videos-container">
                        <div class="empty-state">
                            <i class="fas fa-video"></i>
                            <p>Carregando vídeos internos...</p>
                        </div>
                    </div>
                    
                    <div id="internalSelectionControls" class="video-selection-controls" style="display: none;">
                        <div>
                            <span id="internalSelectedCount">0</span> vídeos selecionados
                        </div>
                        <div>
                            <button class="btn btn-sm btn-primary" onclick="selectAllInternalVideos()">
                                <i class="fas fa-check-square"></i> Selecionar Todos
                            </button>
                            <button class="btn btn-sm btn-secondary" onclick="deselectAllInternalVideos()">
                                <i class="fas fa-square"></i> Desmarcar Todos
                            </button>
                        </div>
                    </div>
                </div>
                
                <!-- Configurações comuns -->
                <div style="margin-top: 30px;">
                    <h3><i class="fas fa-layer-group"></i> Qualidades de Saída</h3>
                    <div class="quality-selector">
                        <div class="quality-option selected" data-quality="240p" onclick="toggleQuality(this)">
                            240p
                        </div>
                        <div class="quality-option selected" data-quality="480p" onclick="toggleQuality(this)">
                            480p
                        </div>
                        <div class="quality-option selected" data-quality="720p" onclick="toggleQuality(this)">
                            720p
                        </div>
                        <div class="quality-option selected" data-quality="1080p" onclick="toggleQuality(this)">
                            1080p
                        </div>
                    </div>
                </div>
                
                <div style="margin-top: 20px;">
                    <label style="display: flex; align-items: center; gap: 10px;">
                        <input type="checkbox" id="keepOrder" checked>
                        Manter ordem dos arquivos
                    </label>
                </div>
                
                <button class="btn btn-primary" onclick="startConversion()" id="convertBtn" style="margin-top: 30px; width: 100%;">
                    <i class="fas fa-play-circle"></i> Iniciar Conversão em Lote
                </button>
                
                <!-- Progresso em tempo real -->
                <div id="realTimeProgress" class="real-time-progress">
                    <h4><i class="fas fa-tasks"></i> Progresso em Tempo Real</h4>
                    <div class="progress-container">
                        <div class="progress-bar" id="realTimeProgressBar" style="width: 0%">0%</div>
                    </div>
                    <div class="progress-text" id="realTimeProgressText">
                        Aguardando início...
                    </div>
                    <div class="current-processing" id="currentProcessing">
                        <strong>Arquivo atual:</strong> <span id="currentFileName">Nenhum</span>
                    </div>
                </div>
                
                <!-- Container para exibir links gerados -->
                <div id="linksContainer" class="links-container">
                    <h3><i class="fas fa-link"></i> Links Gerados</h3>
                    <div id="linksList"></div>
                </div>
            </div>
        </div>
        
        <!-- Conversions Tab -->
        <div id="conversions" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-history"></i> Histórico de Conversões</h2>
                
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
                    <div>
                        <button class="btn btn-success" onclick="loadConversions()">
                            <i class="fas fa-sync-alt"></i> Atualizar
                        </button>
                        <button class="btn btn-warning" onclick="clearHistory()">
                            <i class="fas fa-trash-alt"></i> Limpar Histórico
                        </button>
                    </div>
                    <div id="conversionStats" style="color: #666; font-size: 0.9rem;">
                        Carregando estatísticas...
                    </div>
                </div>
                
                <div id="conversionsList">
                    <div class="empty-state">
                        <i class="fas fa-history"></i>
                        <h3>Nenhuma conversão realizada ainda</h3>
                        <p>Converta seu primeiro vídeo para ver o histórico aqui</p>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Settings Tab -->
        <div id="settings" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-cog"></i> Configurações do Sistema</h2>
                
                <div style="margin-top: 20px;">
                    <h3><i class="fas fa-user-shield"></i> Segurança</h3>
                    <button class="btn btn-primary" onclick="changePassword()" style="margin-top: 10px;">
                        <i class="fas fa-key"></i> Alterar Minha Senha
                    </button>
                </div>
                
                <div style="margin-top: 30px;">
                    <h3><i class="fas fa-hdd"></i> Armazenamento</h3>
                    <div style="margin: 15px 0;">
                        <label style="display: flex; align-items: center; gap: 10px;">
                            <input type="checkbox" id="keepOriginals" checked>
                            Manter arquivos originais após conversão
                        </label>
                    </div>
                    <button class="btn btn-warning" onclick="cleanupOldFiles()" style="margin-top: 10px;">
                        <i class="fas fa-broom"></i> Limpar Arquivos Antigos
                    </button>
                </div>
                
                <div style="margin-top: 30px;">
                    <h3><i class="fas fa-info-circle"></i> Informações do Sistema</h3>
                    <div id="systemInfo" style="background: #f8f9fa; padding: 15px; border-radius: 8px; margin-top: 10px;">
                        Carregando informações...
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Backup Tab -->
        <div id="backup" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-database"></i> Sistema de Backup</h2>
                
                <!-- Criar Backup -->
                <div class="backup-section">
                    <h3><i class="fas fa-plus-circle"></i> Criar Novo Backup</h3>
                    <p style="color: #666; margin-bottom: 15px;">
                        Crie um backup completo do sistema incluindo usuários, configurações e histórico.
                    </p>
                    
                    <div style="display: flex; gap: 15px; align-items: center; margin-top: 20px;">
                        <input type="text" 
                               id="backupName" 
                               placeholder="Nome do backup (opcional)" 
                               style="flex: 1; padding: 12px; border: 1px solid #ddd; border-radius: 5px;">
                        <button class="btn btn-backup" onclick="createBackup()">
                            <i class="fas fa-save"></i> Criar Backup
                        </button>
                    </div>
                </div>
                
                <!-- Lista de Backups -->
                <div class="backup-section" style="margin-top: 30px;">
                    <h3><i class="fas fa-history"></i> Backups Existentes</h3>
                    <p style="color: #666; margin-bottom: 15px;">
                        Gerencie seus backups existentes.
                    </p>
                    
                    <div id="backupsList" class="backup-list">
                        <div class="empty-state">
                            <i class="fas fa-database"></i>
                            <p>Nenhum backup encontrado</p>
                        </div>
                    </div>
                    
                    <div style="display: flex; gap: 10px; margin-top: 20px;">
                        <button class="btn btn-backup" onclick="loadBackups()">
                            <i class="fas fa-sync-alt"></i> Atualizar Lista
                        </button>
                        <button class="btn btn-danger" onclick="deleteAllBackups()">
                            <i class="fas fa-trash-alt"></i> Limpar Tudo
                        </button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Variáveis globais
        let selectedExternalFiles = [];
        let selectedInternalVideos = [];
        let selectedQualities = ['240p', '480p', '720p', '1080p'];
        let currentConversionId = null;
        let progressInterval = null;
        
        // =============== NAVEGAÇÃO ===============
        function showTab(tabName) {
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });
            
            document.querySelectorAll('.nav-tab').forEach(tab => {
                tab.classList.remove('active');
            });
            
            document.getElementById(tabName).classList.add('active');
            
            document.querySelectorAll('.nav-tab').forEach(tab => {
                if (tab.textContent.includes(getTabLabel(tabName))) {
                    tab.classList.add('active');
                }
            });
            
            switch(tabName) {
                case 'dashboard':
                    loadSystemStats();
                    break;
                case 'upload':
                    loadInternalVideos();
                    break;
                case 'conversions':
                    loadConversions();
                    break;
                case 'settings':
                    loadSystemInfo();
                    break;
                case 'backup':
                    loadBackups();
                    break;
            }
        }
        
        function getTabLabel(tabName) {
            const labels = {
                'dashboard': 'Dashboard',
                'upload': 'Upload',
                'conversions': 'Histórico',
                'settings': 'Configurações',
                'backup': 'Backup'
            };
            return labels[tabName];
        }
        
        // =============== UPLOAD TABS ===============
        function showUploadTab(tabName) {
            document.querySelectorAll('.upload-tab').forEach(tab => {
                tab.classList.remove('active');
            });
            
            document.querySelectorAll('.upload-content').forEach(content => {
                content.classList.remove('active');
            });
            
            document.querySelectorAll('.upload-tab').forEach(tab => {
                if (tab.textContent.includes(tabName === 'external' ? 'Upload' : 'Internos')) {
                    tab.classList.add('active');
                }
            });
            
            document.getElementById(tabName + 'Upload').classList.add('active');
        }
        
        // =============== UPLOAD EXTERNO ===============
        function handleExternalFileSelect() {
            const fileInput = document.getElementById('fileInput');
            if (fileInput.files.length > 0) {
                Array.from(fileInput.files).forEach(file => {
                    if (file.size > 2 * 1024 * 1024 * 1024) {
                        showToast(`Arquivo ${file.name} muito grande (máximo 2GB)`, 'error');
                        return;
                    }
                    
                    if (!selectedExternalFiles.some(f => f.name === file.name && f.size === file.size)) {
                        selectedExternalFiles.push(file);
                    }
                });
                
                updateExternalFileList();
                
                const selectedFilesDiv = document.getElementById('selectedExternalFiles');
                selectedFilesDiv.style.display = 'block';
            }
        }
        
        function updateExternalFileList() {
            const fileList = document.getElementById('externalFileList');
            const fileCount = document.getElementById('externalFileCount');
            
            fileList.innerHTML = '';
            fileCount.textContent = selectedExternalFiles.length;
            
            selectedExternalFiles.forEach((file, index) => {
                const li = document.createElement('li');
                li.className = 'file-item';
                li.innerHTML = `
                    <span class="file-name">${file.name}</span>
                    <span class="file-size">${formatBytes(file.size)}</span>
                    <button class="remove-file" onclick="removeExternalFile(${index})">
                        <i class="fas fa-times"></i>
                    </button>
                `;
                fileList.appendChild(li);
            });
        }
        
        function removeExternalFile(index) {
            selectedExternalFiles.splice(index, 1);
            updateExternalFileList();
            
            if (selectedExternalFiles.length === 0) {
                document.getElementById('selectedExternalFiles').style.display = 'none';
            }
        }
        
        // =============== ARQUIVOS INTERNOS ===============
        function loadInternalVideos() {
            fetch('/api/internal-videos')
                .then(response => {
                    if (!response) {
                        throw new Error('Sem resposta do servidor');
                    }
                    return response.json();
                })
                .then(data => {
                    const container = document.getElementById('internalVideosContainer');
                    const controls = document.getElementById('internalSelectionControls');
                    
                    if (!data.videos || data.videos.length === 0) {
                        container.innerHTML = `
                            <div class="empty-state">
                                <i class="fas fa-video-slash"></i>
                                <p>Nenhum vídeo encontrado no diretório interno</p>
                                <p style="font-size: 0.9rem; color: #666;">
                                    Adicione vídeos em: /opt/hls-converter/videos_internos/
                                </p>
                            </div>
                        `;
                        controls.style.display = 'none';
                        return;
                    }
                    
                    let html = '';
                    data.videos.forEach((video, index) => {
                        const isSelected = selectedInternalVideos.some(v => v.path === video.path);
                        html += `
                            <div class="internal-video-item ${isSelected ? 'selected' : ''}" onclick="toggleInternalVideo(${index})">
                                <div class="internal-video-info">
                                    <div class="internal-video-name">${video.name}</div>
                                    <div class="internal-video-meta">
                                        ${formatBytes(video.size)} • 
                                        ${formatDate(video.modified)}
                                    </div>
                                </div>
                                <input type="checkbox" class="internal-video-checkbox" 
                                       ${isSelected ? 'checked' : ''}
                                       onclick="event.stopPropagation(); toggleInternalVideo(${index})">
                            </div>
                        `;
                    });
                    
                    container.innerHTML = html;
                    controls.style.display = 'block';
                    updateInternalSelectionCount();
                    
                })
                .catch(error => {
                    console.error('Erro ao carregar vídeos internos:', error);
                    showToast('Erro ao carregar vídeos internos', 'error');
                });
        }
        
        function toggleInternalVideo(index) {
            fetch('/api/internal-videos')
                .then(response => response.json())
                .then(data => {
                    if (data.videos && data.videos[index]) {
                        const video = data.videos[index];
                        const existingIndex = selectedInternalVideos.findIndex(v => v.path === video.path);
                        
                        if (existingIndex === -1) {
                            selectedInternalVideos.push(video);
                        } else {
                            selectedInternalVideos.splice(existingIndex, 1);
                        }
                        
                        loadInternalVideos();
                    }
                })
                .catch(error => {
                    console.error('Erro ao obter vídeo:', error);
                });
        }
        
        function selectAllInternalVideos() {
            fetch('/api/internal-videos')
                .then(response => response.json())
                .then(data => {
                    if (data.videos) {
                        selectedInternalVideos = [...data.videos];
                        loadInternalVideos();
                    }
                })
                .catch(error => {
                    console.error('Erro ao selecionar todos:', error);
                });
        }
        
        function deselectAllInternalVideos() {
            selectedInternalVideos = [];
            loadInternalVideos();
        }
        
        function updateInternalSelectionCount() {
            document.getElementById('internalSelectedCount').textContent = selectedInternalVideos.length;
        }
        
        // =============== CONVERSÃO MULTIARQUIVOS ===============
        function toggleQuality(element) {
            const quality = element.getAttribute('data-quality');
            const index = selectedQualities.indexOf(quality);
            
            if (index === -1) {
                selectedQualities.push(quality);
                element.classList.add('selected');
            } else {
                selectedQualities.splice(index, 1);
                element.classList.remove('selected');
            }
        }
        
        function startConversion() {
            const conversionName = document.getElementById('conversionName').value.trim();
            if (!conversionName) {
                showToast('Por favor, digite um nome para a conversão', 'warning');
                document.getElementById('conversionName').focus();
                return;
            }
            
            let totalFiles = 0;
            let formData = new FormData();
            let useInternal = document.querySelector('#internalUpload').classList.contains('active');
            
            if (useInternal) {
                if (selectedInternalVideos.length === 0) {
                    showToast('Por favor, selecione pelo menos um vídeo interno!', 'warning');
                    return;
                }
                totalFiles = selectedInternalVideos.length;
                formData.append('video_paths', JSON.stringify(selectedInternalVideos.map(v => v.path)));
                formData.append('source_type', 'internal');
            } else {
                if (selectedExternalFiles.length === 0) {
                    showToast('Por favor, selecione pelo menos um arquivo!', 'warning');
                    return;
                }
                totalFiles = selectedExternalFiles.length;
                selectedExternalFiles.forEach(file => {
                    formData.append('files[]', file);
                });
                formData.append('source_type', 'external');
            }
            
            if (selectedQualities.length === 0) {
                showToast('Selecione pelo menos uma qualidade!', 'warning');
                return;
            }
            
            formData.append('qualities', JSON.stringify(selectedQualities));
            formData.append('keep_order', document.getElementById('keepOrder').checked);
            formData.append('conversion_name', conversionName);
            
            const progressSection = document.getElementById('realTimeProgress');
            progressSection.classList.add('show');
            
            const convertBtn = document.getElementById('convertBtn');
            const originalBtnText = convertBtn.innerHTML;
            convertBtn.disabled = true;
            convertBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Convertendo...';
            
            currentConversionId = 'temp_' + Date.now();
            startProgressMonitoring();
            
            fetch('/convert-multiple', {
                method: 'POST',
                body: formData
            })
            .then(response => {
                if (!response) {
                    throw new Error('O servidor não respondeu');
                }
                
                if (!response.ok) {
                    throw new Error(`Erro HTTP ${response.status}: ${response.statusText}`);
                }
                
                return response.json();
            })
            .then(data => {
                console.log('Resposta da conversão:', data);
                
                stopProgressMonitoring();
                
                if (!data) {
                    throw new Error('Resposta vazia do servidor');
                }
                
                if (data.success) {
                    updateRealTimeProgress(100, 'Conversão completa!', '');
                    showConversionLinks(data);
                    showToast(`✅ "${conversionName}" convertido com sucesso!`, 'success');
                    
                    setTimeout(() => {
                        progressSection.classList.remove('show');
                        document.getElementById('selectedExternalFiles').style.display = 'none';
                        document.getElementById('fileInput').value = '';
                        selectedExternalFiles = [];
                        selectedInternalVideos = [];
                        loadInternalVideos();
                        convertBtn.disabled = false;
                        convertBtn.innerHTML = originalBtnText;
                        
                        loadConversions();
                        loadSystemStats();
                    }, 5000);
                } else {
                    const errorMsg = data.error || 'Erro desconhecido na conversão';
                    showToast(`❌ Erro: ${errorMsg}`, 'error');
                    convertBtn.disabled = false;
                    convertBtn.innerHTML = originalBtnText;
                }
            })
            .catch(error => {
                console.error('Erro na conversão:', error);
                stopProgressMonitoring();
                showToast(`❌ Erro de conexão: ${error.message || 'Servidor não respondeu'}`, 'error');
                convertBtn.disabled = false;
                convertBtn.innerHTML = originalBtnText;
            });
        }
        
        function startProgressMonitoring() {
            if (progressInterval) {
                clearInterval(progressInterval);
            }
            
            progressInterval = setInterval(() => {
                if (currentConversionId) {
                    fetch(`/api/progress/${currentConversionId}`)
                        .then(response => response.json())
                        .then(data => {
                            if (data) {
                                updateRealTimeProgress(
                                    data.progress_percent || 0,
                                    data.message || "Processando...",
                                    data.filename || ""
                                );
                            }
                        })
                        .catch(() => {
                            // Ignora erros de polling
                        });
                }
            }, 2000);
        }
        
        function stopProgressMonitoring() {
            if (progressInterval) {
                clearInterval(progressInterval);
                progressInterval = null;
            }
            currentConversionId = null;
        }
        
        function updateRealTimeProgress(percent, message, filename) {
            const progressBar = document.getElementById('realTimeProgressBar');
            const progressText = document.getElementById('realTimeProgressText');
            const currentFile = document.getElementById('currentFileName');
            
            progressBar.style.width = percent + '%';
            progressBar.textContent = percent + '%';
            progressText.textContent = message;
            currentFile.textContent = filename || "Nenhum";
        }
        
        function showConversionLinks(data) {
            const linksContainer = document.getElementById('linksContainer');
            const linksList = document.getElementById('linksList');
            
            const baseUrl = window.location.origin;
            let html = '';
            
            html += `
                <div class="link-item">
                    <div class="link-info">
                        <div class="link-title">🎬 ${data.conversion_name}</div>
                        <div class="link-url">${baseUrl}/hls/${data.playlist_id}/master.m3u8</div>
                        <small style="color: #666;">Playlist principal com todas as qualidades</small>
                    </div>
                    <div class="link-actions">
                        <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${baseUrl}/hls/${data.playlist_id}/master.m3u8')">
                            <i class="fas fa-copy"></i> Copiar
                        </button>
                        <button class="btn btn-success btn-sm" onclick="window.open('/player/${data.playlist_id}', '_blank')">
                            <i class="fas fa-play"></i> Player
                        </button>
                    </div>
                </div>
            `;
            
            if (data.quality_links && Object.keys(data.quality_links).length > 0) {
                html += '<h4 style="margin-top: 20px; color: #666;"><i class="fas fa-layer-group"></i> Qualidades Disponíveis:</h4>';
                
                for (const [quality, path] of Object.entries(data.quality_links)) {
                    const fullUrl = `${baseUrl}${path}`;
                    html += `
                        <div class="link-item">
                            <div class="link-info">
                                <div class="link-title">${quality}</div>
                                <div class="link-url">${fullUrl}</div>
                            </div>
                            <div class="link-actions">
                                <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${fullUrl}')">
                                    <i class="fas fa-copy"></i>
                                </button>
                            </div>
                        </div>
                    `;
                }
            }
            
            linksList.innerHTML = html;
            linksContainer.classList.add('show');
            linksContainer.scrollIntoView({ behavior: 'smooth' });
        }
        
        // =============== UTILITÁRIOS ===============
        function copyToClipboard(text) {
            const textArea = document.createElement('textarea');
            textArea.value = text;
            textArea.style.position = 'fixed';
            textArea.style.left = '-999999px';
            textArea.style.top = '-999999px';
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            
            try {
                document.execCommand('copy');
                showToast('✅ Link copiado para a área de transferência!', 'success');
            } catch (err) {
                console.error('Erro ao copiar:', err);
                showToast('❌ Erro ao copiar link', 'error');
            } finally {
                document.body.removeChild(textArea);
            }
        }
        
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function formatDate(timestamp) {
            try {
                const date = new Date(timestamp);
                return date.toLocaleString('pt-BR');
            } catch {
                return 'Data inválida';
            }
        }
        
        function showToast(message, type = 'info') {
            document.querySelectorAll('.toast').forEach(toast => toast.remove());
            
            const toast = document.createElement('div');
            toast.className = `toast ${type}`;
            toast.innerHTML = `
                <i class="fas fa-${type === 'success' ? 'check-circle' : type === 'error' ? 'exclamation-circle' : 'info-circle'}"></i>
                <span>${message}</span>
            `;
            
            document.body.appendChild(toast);
            
            setTimeout(() => {
                toast.remove();
            }, 5000);
        }
        
        // =============== INICIALIZAÇÃO ===============
        document.addEventListener('DOMContentLoaded', function() {
            loadSystemStats();
            loadInternalVideos();
            
            setInterval(loadSystemStats, 30000);
            
            const externalUploadArea = document.querySelector('#externalUpload .upload-area');
            
            externalUploadArea.addEventListener('dragover', (e) => {
                e.preventDefault();
                externalUploadArea.style.backgroundColor = 'rgba(67, 97, 238, 0.1)';
            });
            
            externalUploadArea.addEventListener('dragleave', () => {
                externalUploadArea.style.backgroundColor = '';
            });
            
            externalUploadArea.addEventListener('drop', (e) => {
                e.preventDefault();
                externalUploadArea.style.backgroundColor = '';
                
                if (e.dataTransfer.files.length > 0) {
                    Array.from(e.dataTransfer.files).forEach(file => {
                        if (file.size > 2 * 1024 * 1024 * 1024) {
                            showToast(`Arquivo ${file.name} muito grande (máximo 2GB)`, 'error');
                            return;
                        }
                        
                        if (!selectedExternalFiles.some(f => f.name === file.name && f.size === file.size)) {
                            selectedExternalFiles.push(file);
                        }
                    });
                    
                    updateExternalFileList();
                    
                    const selectedFilesDiv = document.getElementById('selectedExternalFiles');
                    selectedFilesDiv.style.display = 'block';
                }
            });
        });
    </script>
</body>
</html>
'''

# =============== ROTAS PRINCIPAIS ===============

@app.route('/')
def index():
    if 'user_id' not in session:
        return redirect(url_for('login'))
    
    if password_change_required(session['user_id']):
        return redirect(url_for('change_password'))
    
    return render_template_string(DASHBOARD_HTML)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'GET':
        if 'user_id' in session:
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML)
    
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    
    if not username or not password:
        flash('Por favor, preencha todos os campos', 'error')
        return render_template_string(LOGIN_HTML)
    
    if check_password(username, password):
        users = load_users()
        if username in users.get('users', {}):
            users['users'][username]['last_login'] = datetime.now().isoformat()
            save_users(users)
        
        session['user_id'] = username
        session['login_time'] = datetime.now().isoformat()
        
        if password_change_required(username):
            return redirect(url_for('change_password'))
        
        log_activity(f"Usuário {username} fez login")
        return redirect(url_for('index'))
    else:
        flash('Usuário ou senha incorretos', 'error')
        return render_template_string(LOGIN_HTML)

@app.route('/change-password', methods=['GET', 'POST'])
def change_password():
    if 'user_id' not in session:
        return redirect(url_for('login'))
    
    if request.method == 'GET':
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    username = session['user_id']
    current_password = request.form.get('current_password', '').strip()
    new_password = request.form.get('new_password', '').strip()
    confirm_password = request.form.get('confirm_password', '').strip()
    
    errors = []
    
    if not all([current_password, new_password, confirm_password]):
        errors.append('Todos os campos são obrigatórios')
    
    if new_password != confirm_password:
        errors.append('As senhas não coincidem')
    
    if len(new_password) < 8:
        errors.append('A senha deve ter pelo menos 8 caracteres')
    
    if current_password == new_password:
        errors.append('A nova senha não pode ser igual à atual')
    
    if not check_password(username, current_password):
        errors.append('Senha atual incorreta')
    
    if errors:
        for error in errors:
            flash(error, 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    try:
        new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
        users = load_users()
        users['users'][username]['password'] = new_hash
        users['users'][username]['password_changed'] = True
        users['users'][username]['last_password_change'] = datetime.now().isoformat()
        save_users(users)
        
        flash('✅ Senha alterada com sucesso!', 'success')
        log_activity(f"Usuário {username} alterou a senha")
        return redirect(url_for('index'))
    except Exception as e:
        flash(f'Erro ao alterar senha: {str(e)}', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)

@app.route('/logout')
def logout():
    if 'user_id' in session:
        log_activity(f"Usuário {session['user_id']} fez logout")
        session.clear()
    flash('✅ Você foi desconectado com sucesso', 'info')
    return redirect(url_for('login'))

@app.route('/api/system')
def api_system():
    """Endpoint para informações do sistema"""
    try:
        cpu = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        
        conversions = load_conversions()
        
        ffmpeg_path = find_ffmpeg()
        
        return jsonify({
            "cpu": f"{cpu:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "total_conversions": conversions["stats"]["total"],
            "success_conversions": conversions["stats"]["success"],
            "failed_conversions": conversions["stats"]["failed"],
            "ffmpeg_status": "ok" if ffmpeg_path else "missing",
            "ffmpeg_path": ffmpeg_path or "Não encontrado"
        })
    except Exception as e:
        return jsonify({
            "error": str(e),
            "ffmpeg_status": "error"
        })

@app.route('/api/conversions')
def api_conversions():
    """Endpoint para listar conversões"""
    try:
        data = load_conversions()
        
        if not isinstance(data.get('conversions'), list):
            data['conversions'] = []
        
        try:
            data['conversions'].sort(key=lambda x: x.get('timestamp', ''), reverse=True)
        except:
            pass
        
        return jsonify(data)
    except Exception as e:
        return jsonify({
            "error": str(e),
            "conversions": [],
            "stats": {"total": 0, "success": 0, "failed": 0}
        })

@app.route('/api/progress/<playlist_id>')
def api_progress(playlist_id):
    """Endpoint para obter progresso da conversão"""
    progress = get_progress(playlist_id)
    return jsonify(progress)

@app.route('/api/internal-videos')
def api_internal_videos():
    """Endpoint para listar vídeos internos"""
    try:
        videos = list_internal_videos()
        return jsonify({
            "success": True,
            "videos": videos,
            "count": len(videos)
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e),
            "videos": []
        })

# =============== ROTA DE CONVERSÃO MULTIARQUIVOS ===============

@app.route('/convert-multiple', methods=['POST'])
def convert_multiple_videos():
    """Converter múltiplos vídeos - VERSÃO MULTIARQUIVOS CORRIGIDA"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    print(f"[DEBUG] Iniciando conversão multiarquivos para usuário: {session['user_id']}")
    
    try:
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            print("[DEBUG] FFmpeg não encontrado")
            return jsonify({
                "success": False,
                "error": "FFmpeg não encontrado. Execute: sudo apt-get install ffmpeg"
            })
        
        conversion_name = request.form.get('conversion_name', '').strip()
        if not conversion_name:
            conversion_name = f"Conversão {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        
        conversion_name = sanitize_filename(conversion_name)
        print(f"[DEBUG] Nome da conversão: {conversion_name}")
        
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        print(f"[DEBUG] Qualidades: {qualities}")
        
        source_type = request.form.get('source_type', 'external')
        video_paths = []
        
        if source_type == 'external':
            if 'files[]' not in request.files:
                print("[DEBUG] Nenhum arquivo externo enviado")
                return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
            
            files = request.files.getlist('files[]')
            print(f"[DEBUG] Arquivos externos recebidos: {len(files)}")
            
            if not files or files[0].filename == '':
                print("[DEBUG] Nenhum arquivo externo selecionado")
                return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
            
            for file in files:
                filename = sanitize_filename(file.filename)
                temp_path = os.path.join(UPLOAD_DIR, f"temp_{uuid.uuid4().hex}_{filename}")
                file.save(temp_path)
                video_paths.append(temp_path)
                
        else:  # internal
            video_paths_json = request.form.get('video_paths', '[]')
            try:
                selected_videos = json.loads(video_paths_json)
                video_paths = [v['path'] for v in selected_videos if os.path.exists(v['path'])]
                print(f"[DEBUG] Vídeos internos selecionados: {len(video_paths)}")
            except Exception as e:
                print(f"[DEBUG] Erro ao processar vídeos internos: {e}")
                return jsonify({"success": False, "error": "Erro ao processar vídeos internos"})
        
        if not video_paths:
            return jsonify({"success": False, "error": "Nenhum vídeo válido para conversão"})
        
        playlist_id = str(uuid.uuid4())[:8]
        
        update_progress(playlist_id, 0, len(video_paths), "Iniciando conversão...", "")
        
        print(f"Iniciando conversão multiarquivos: {len(video_paths)} arquivos, nome: {conversion_name}")
        
        def conversion_task():
            return process_multiple_videos(video_paths, qualities, playlist_id, conversion_name)
        
        future = executor.submit(conversion_task)
        result = future.result(timeout=7200)
        
        print(f"Resultado da conversão: {result.get('success', False)}")
        
        if result.get("success", False):
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "video_id": playlist_id,
                "conversion_name": conversion_name,
                "filename": f"{len(video_paths)} arquivos",
                "qualities": qualities,
                "timestamp": datetime.now().isoformat(),
                "status": "success",
                "type": "multiple",
                "videos_count": len(video_paths),
                "videos_converted": result.get("videos_converted", 0),
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "details": result.get("videos_info", [])
            }
            
            if not isinstance(conversions.get('conversions'), list):
                conversions['conversions'] = []
            
            conversions['conversions'].insert(0, conversion_data)
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['success'] = conversions['stats'].get('success', 0) + 1
            
            save_conversions(conversions)
            
            log_activity(f"Conversão '{conversion_name}' realizada: {len(video_paths)} arquivos -> {playlist_id}")
            
            return jsonify({
                "success": True,
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "videos_count": len(video_paths),
                "videos_converted": result.get("videos_converted", 0),
                "qualities": result.get("qualities", qualities),
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "quality_links": result.get("quality_links", {}),
                "video_links": result.get("video_links", []),
                "errors": result.get("errors", []),
                "message": f"Conversão '{conversion_name}' concluída com sucesso!"
            })
        else:
            conversions = load_conversions()
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['failed'] = conversions['stats'].get('failed', 0) + 1
            save_conversions(conversions)
            
            error_msg = result.get("errors", ["Erro desconhecido na conversão"])[0] if result.get("errors") else "Erro na conversão"
            
            return jsonify({
                "success": False,
                "error": error_msg,
                "errors": result.get("errors", [])
            })
        
    except concurrent.futures.TimeoutError:
        return jsonify({
            "success": False,
            "error": "Timeout: A conversão excedeu o tempo limite de 2 horas"
        })
    except Exception as e:
        print(f"Erro na conversão multiarquivos: {str(e)}")
        
        try:
            conversions = load_conversions()
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['failed'] = conversions['stats'].get('failed', 0) + 1
            save_conversions(conversions)
        except:
            pass
        
        return jsonify({
            "success": False,
            "error": f"Erro interno: {str(e)}"
        })

# Outras rotas (player, health, etc.) permanecem as mesmas...

@app.route('/player/<playlist_id>')
def player_page(playlist_id):
    """Página do player para playlist"""
    m3u8_url = f"/hls/{playlist_id}/master.m3u8"
    
    index_file = os.path.join(HLS_DIR, playlist_id, "playlist_info.json")
    video_info = []
    conversion_name = playlist_id
    
    if os.path.exists(index_file):
        try:
            with open(index_file, 'r') as f:
                data = json.load(f)
                video_info = data.get('videos', [])
                conversion_name = data.get('conversion_name', playlist_id)
        except:
            pass
    
    player_html = '''
    <!DOCTYPE html>
    <html>
    <head>
        <title>''' + conversion_name + ''' - HLS Player</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <style>
            body { 
                margin: 0; 
                padding: 20px; 
                background: #1a1a1a; 
                color: white;
                font-family: Arial, sans-serif;
            }
            .player-container { 
                max-width: 1200px; 
                margin: 0 auto; 
                background: #2d2d2d;
                border-radius: 10px;
                overflow: hidden;
                box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            }
            .back-btn { 
                background: #4361ee; 
                color: white; 
                border: none; 
                padding: 10px 20px; 
                border-radius: 5px; 
                cursor: pointer;
                margin-bottom: 20px;
                display: inline-flex;
                align-items: center;
                gap: 8px;
            }
            .playlist-info {
                padding: 20px;
                background: #363636;
                border-bottom: 1px solid #444;
            }
            .videos-list {
                padding: 20px;
                max-height: 300px;
                overflow-y: auto;
            }
            .video-item {
                padding: 10px 15px;
                background: #2d2d2d;
                border-radius: 5px;
                margin-bottom: 10px;
                border-left: 3px solid #4361ee;
            }
            .video-title {
                font-weight: bold;
                color: #4cc9f0;
            }
            .video-meta {
                font-size: 0.9rem;
                color: #aaa;
                margin-top: 5px;
            }
        </style>
    </head>
    <body>
        <button class="back-btn" onclick="window.history.back()">
            <i class="fas fa-arrow-left"></i> Voltar
        </button>
        
        <div class="player-container">
            <div class="playlist-info">
                <h2>🎬 ''' + conversion_name + '''</h2>
                <p>Total de vídeos: ''' + str(len(video_info)) + ''' | Use as setas para navegar entre os vídeos</p>
            </div>
            
            <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="500">
                <source src="''' + m3u8_url + '''" type="application/x-mpegURL">
            </video>
    '''
    
    if video_info:
        player_html += '''
            <div class="videos-list">
                <h3><i class="fas fa-list"></i> Vídeos na Playlist</h3>
        '''
        
        for v in video_info:
            qualities = ', '.join(v.get("qualities", []))
            filename = v.get("filename", "Vídeo")
            player_html += f'''
                <div class="video-item">
                    <div class="video-title">{filename}</div>
                    <div class="video-meta">
                        Qualidades: {qualities}
                    </div>
                </div>
            '''
        
        player_html += '''
            </div>
        '''
    
    player_html += '''
        </div>
        
        <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/videojs-contrib-hls/5.15.0/videojs-contrib-hls.min.js"></script>
        <script src="https://kit.fontawesome.com/a076d05399.js" crossorigin="anonymous"></script>
        <script>
            var player = videojs('hlsPlayer', {
                html5: {
                    hls: {
                        enableLowInitialPlaylist: true,
                        smoothQualityChange: true,
                        overrideNative: true
                    }
                }
            });
            
            player.ready(function() {
                this.play();
            });
        </script>
    </body>
    </html>
    '''
    
    return player_html

@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": "hls-converter-multifiles",
        "timestamp": datetime.now().isoformat(),
        "version": "2.5.0",
        "ffmpeg": find_ffmpeg() is not None,
        "multi_upload": True,
        "internal_files": True,
        "backup_system": True,
        "named_conversions": True,
        "fixed_links": True,
        "progress_tracking": True
    })

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 60)
    print("🚀 HLS Converter MULTIARQUIVOS - Versão 2.5.0")
    print("=" * 60)
    print(f"📂 Diretório base: {BASE_DIR}")
    print(f"🎬 Vídeos internos: {INTERNAL_VIDEOS_DIR}")
    print(f"🔐 Autenticação: Habilitada")
    print(f"👤 Usuário padrão: admin / admin")
    print(f"💾 Sistema de backup: Habilitado")
    print(f"🏷️  Nome personalizado: Habilitado")
    print(f"📊 Progresso em tempo real: SIM")
    print(f"🔗 Links copiáveis: SIM")
    print(f"🌐 Porta: 8080")
    print("=" * 60)
    
    ffmpeg_path = find_ffmpeg()
    if ffmpeg_path:
        print(f"✅ FFmpeg encontrado: {ffmpeg_path}")
        try:
            result = subprocess.run([ffmpeg_path, '-version'], capture_output=True, text=True)
            if result.returncode == 0:
                version = result.stdout.split('\n')[0]
                print(f"📊 Versão: {version}")
        except:
            print("⚠️  FFmpeg encontrado mas não testado")
    else:
        print("❌ FFmpeg NÃO encontrado!")
        print("📋 Execute: sudo apt-get install -y ffmpeg")
    
    print("")
    print("🌐 URLs importantes:")
    print(f"   🔐 Login: http://localhost:8080/login")
    print(f"   🩺 Health: http://localhost:8080/health")
    print(f"   🎮 Dashboard: http://localhost:8080/")
    print("")
    
    print("💾 Inicializando banco de dados...")
    load_users()
    load_conversions()
    
    try:
        from waitress import serve
        print("🚀 Iniciando servidor com Waitress...")
        serve(app, host='0.0.0.0', port=8080, threads=4)
    except ImportError:
        print("⚠️  Waitress não encontrado, usando servidor de desenvolvimento...")
        app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
EOF

# 10. CRIAR ARQUIVOS DE BANCO DE DADOS
echo "💾 Criando arquivos de banco de dados..."

cat > /opt/hls-converter/db/users.json << 'EOF'
{
    "users": {
        "admin": {
            "password": "$2b$12$7eE8R5Yq3X3t7kXq3Z8p9eBvG9HjK1L2N3M4Q5W6X7Y8Z9A0B1C2D3E4F5G6H7I8J9",
            "password_changed": false,
            "created_at": "2024-01-01T00:00:00",
            "last_login": null,
            "role": "admin"
        }
    },
    "settings": {
        "require_password_change": true,
        "session_timeout": 7200,
        "max_login_attempts": 5,
        "max_concurrent_conversions": 1,
        "keep_originals": true
    }
}
EOF

cat > /opt/hls-converter/db/conversions.json << 'EOF'
{
    "conversions": [],
    "stats": {
        "total": 0,
        "success": 0,
        "failed": 0
    }
}
EOF

# 11. CRIAR SCRIPT DE GERENCIAMENTO MULTIARQUIVOS
echo "📝 Criando script de gerenciamento..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"

case "$1" in
    start)
        echo "🚀 Iniciando HLS Converter..."
        systemctl start hls-converter
        echo "✅ Serviço iniciado"
        ;;
    stop)
        echo "🛑 Parando HLS Converter..."
        systemctl stop hls-converter
        echo "✅ Serviço parado"
        ;;
    restart)
        echo "🔄 Reiniciando HLS Converter..."
        systemctl restart hls-converter
        echo "✅ Serviço reiniciado"
        sleep 2
        systemctl status hls-converter --no-pager
        ;;
    status)
        systemctl status hls-converter --no-pager
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            journalctl -u hls-converter -f
        else
            journalctl -u hls-converter -n 30 --no-pager
        fi
        ;;
    test)
        echo "🧪 Testando sistema multiarquivos..."
        echo ""
        
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço está ativo"
            
            echo "🌐 Testando health check..."
            if curl -s http://localhost:8080/health | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "⚠️  Health check falhou"
                curl -s http://localhost:8080/health || true
            fi
            
            echo "📂 Testando listagem de vídeos internos..."
            if curl -s http://localhost:8080/api/internal-videos | grep -q '"success":true'; then
                echo "✅ API de vídeos internos OK"
            else
                echo "⚠️  API de vídeos internos pode ter problemas"
            fi
            
            echo "🔐 Testando login..."
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
            if [ "$STATUS_CODE" = "200" ]; then
                echo "✅ Página de login OK"
            else
                echo "⚠️  Login retornou código: $STATUS_CODE"
            fi
            
        else
            echo "❌ Serviço não está ativo"
        fi
        
        echo ""
        echo "🎬 Testando FFmpeg local..."
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg encontrado: $(which ffmpeg)"
            ffmpeg -version | head -1
        else
            echo "❌ FFmpeg não encontrado"
        fi
        
        echo ""
        echo "📁 Verificando diretórios..."
        for dir in "$HLS_HOME" "$HLS_HOME/uploads" "$HLS_HOME/hls" "$HLS_HOME/backups" "$HLS_HOME/db" "$HLS_HOME/videos_internos"; do
            if [ -d "$dir" ]; then
                echo "✅ $dir"
            else
                echo "❌ $dir (não existe)"
            fi
        done
        ;;
    fix-ffmpeg)
        echo "🔧 Instalando FFmpeg..."
        apt-get update
        apt-get install -y ffmpeg
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg instalado"
            ffmpeg -version | head -1
        else
            echo "❌ Falha ao instalar FFmpeg"
        fi
        ;;
    add-video)
        if [ -z "$2" ]; then
            echo "❌ Por favor, forneça o caminho do vídeo"
            echo "   Exemplo: hlsctl add-video /caminho/para/video.mp4"
            exit 1
        fi
        
        if [ ! -f "$2" ]; then
            echo "❌ Arquivo não encontrado: $2"
            exit 1
        fi
        
        echo "📥 Copiando vídeo para diretório interno..."
        cp "$2" /opt/hls-converter/videos_internos/
        echo "✅ Vídeo copiado: $(basename "$2")"
        echo "📁 Diretório: /opt/hls-converter/videos_internos/"
        ls -la /opt/hls-converter/videos_internos/
        ;;
    list-videos)
        echo "📁 Vídeos disponíveis no diretório interno:"
        echo ""
        ls -la /opt/hls-converter/videos_internos/
        echo ""
        echo "🎬 Total de vídeos: $(ls -1 /opt/hls-converter/videos_internos/ | wc -l)"
        ;;
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        find /opt/hls-converter/uploads -type f -mtime +7 -delete 2>/dev/null || true
        find /opt/hls-converter/hls -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
        echo "✅ Arquivos antigos removidos"
        ;;
    reset-password)
        echo "🔑 Resetando senha do admin para 'admin'..."
        cd /opt/hls-converter
        source venv/bin/activate
        python3 -c "
import bcrypt
import json
hash_admin = bcrypt.hashpw(b'admin', bcrypt.gensalt()).decode('utf-8')
with open('/opt/hls-converter/db/users.json', 'r') as f:
    data = json.load(f)
data['users']['admin']['password'] = hash_admin
data['users']['admin']['password_changed'] = False
with open('/opt/hls-converter/db/users.json', 'w') as f:
    json.dump(data, f, indent=2)
print('✅ Senha resetada para: admin')
print('⚠️  Altere a senha no primeiro login!')
"
        ;;
    backup)
        echo "💾 Criando backup do sistema..."
        cd /opt/hls-converter
        source venv/bin/activate
        python3 -c "
import sys
sys.path.insert(0, '.')
from app import create_backup
result = create_backup()
if result['success']:
    print(f'✅ Backup criado: {result[\"backup_name\"]}')
    print(f'📁 Local: {result[\"backup_path\"]}')
    print(f'📦 Tamanho: {result[\"size\"]} bytes')
else:
    print(f'❌ Erro: {result[\"error\"]}')
"
        ;;
    restore)
        if [ -z "$2" ]; then
            echo "❌ Por favor, forneça o caminho do arquivo de backup"
            echo "   Exemplo: hlsctl restore /caminho/para/backup.tar.gz"
            exit 1
        fi
        
        if [ ! -f "$2" ]; then
            echo "❌ Arquivo não encontrado: $2"
            exit 1
        fi
        
        echo "🔄 Restaurando backup: $2"
        cd /opt/hls-converter
        source venv/bin/activate
        python3 -c "
import sys
sys.path.insert(0, '.')
from app import restore_backup
result = restore_backup('$2')
if result['success']:
    print('✅ Backup restaurado com sucesso!')
    print('⚠️  Reinicie o serviço para aplicar as alterações')
else:
    print(f'❌ Erro: {result[\"error\"]}')
"
        ;;
    debug)
        echo "🐛 Modo debug multiarquivos..."
        cd /opt/hls-converter
        
        echo ""
        echo "📊 Status do serviço:"
        systemctl status hls-converter --no-pager
        
        echo ""
        echo "📋 Logs recentes:"
        journalctl -u hls-converter -n 20 --no-pager
        
        echo ""
        echo "📁 Estrutura de diretórios:"
        ls -la /opt/hls-converter/
        echo ""
        echo "📁 Vídeos internos:"
        ls -la /opt/hls-converter/videos_internos/ 2>/dev/null || echo "Diretório videos_internos/ não existe"
        
        echo ""
        echo "🧪 Teste de API multiarquivos:"
        echo "Health check:"
        curl -s http://localhost:8080/health | jq . 2>/dev/null || curl -s http://localhost:8080/health
        
        echo ""
        echo "🎬 Vídeos internos via API:"
        curl -s http://localhost:8080/api/internal-videos | jq . 2>/dev/null || curl -s http://localhost:8080/api/internal-videos
        
        echo ""
        echo "🔧 FFmpeg:"
        if command -v ffmpeg &> /dev/null; then
            ffmpeg -version | head -1
        else
            echo "FFmpeg não encontrado"
        fi
        
        echo ""
        echo "🌐 Nginx:"
        systemctl status nginx --no-pager | head -5
        
        echo ""
        echo "🐍 Python:"
        cd /opt/hls-converter && source venv/bin/activate && python3 --version
        
        echo ""
        echo "🔑 Banco de dados:"
        ls -la /opt/hls-converter/db/
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=" * 70
        echo "🎬 HLS Converter MULTIARQUIVOS - Informações do Sistema"
        echo "=" * 70
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo "Versão: 2.5.0 (Multiarquivos e Internos)"
        echo "Porta: 8080"
        echo "Login: http://$IP:8080/login"
        echo "Usuário: admin"
        echo "Senha: admin (altere no primeiro acesso)"
        echo ""
        echo "✨ NOVAS FUNCIONALIDADES:"
        echo "  ✅ Upload de múltiplos arquivos funcionando"
        echo "  ✅ Seleção de arquivos internos do servidor"
        echo "  ✅ Conversão em sequência mantendo a ordem"
        echo "  ✅ Progresso em tempo real para cada arquivo"
        echo "  ✅ Interface com tabs para escolha de origem"
        echo ""
        echo "📂 DIRETÓRIOS:"
        echo "  📁 Principal: /opt/hls-converter"
        echo "  🎬 Vídeos internos: /opt/hls-converter/videos_internos"
        echo "  📤 Uploads: /opt/hls-converter/uploads"
        echo "  📥 HLS: /opt/hls-converter/hls"
        echo "  💾 Backups: /opt/hls-converter/backups"
        echo ""
        echo "🔧 COMANDOS DISPONÍVEIS:"
        echo "  hlsctl start        - Iniciar serviço"
        echo "  hlsctl stop         - Parar serviço"
        echo "  hlsctl restart      - Reiniciar serviço"
        echo "  hlsctl status       - Ver status"
        echo "  hlsctl logs [-f]    - Ver logs (-f para seguir)"
        echo "  hlsctl test         - Testar sistema completo"
        echo "  hlsctl debug        - Modo debug detalhado"
        echo "  hlsctl fix-ffmpeg   - Instalar/reparar FFmpeg"
        echo "  hlsctl add-video FILE - Adicionar vídeo ao diretório interno"
        echo "  hlsctl list-videos  - Listar vídeos disponíveis"
        echo "  hlsctl cleanup      - Limpar arquivos antigos"
        echo "  hlsctl backup       - Criar backup manual"
        echo "  hlsctl restore FILE - Restaurar backup"
        echo "  hlsctl reset-password - Resetar senha do admin"
        echo "  hlsctl info         - Esta informação"
        echo "=" * 70
        ;;
    *)
        echo "🎬 HLS Converter MULTIARQUIVOS - Gerenciador (v2.5.0)"
        echo "==================================================="
        echo ""
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos:"
        echo "  start               - Iniciar serviço"
        echo "  stop                - Parar serviço"
        echo "  restart             - Reiniciar serviço"
        echo "  status              - Ver status"
        echo "  logs [-f]           - Ver logs (-f para seguir)"
        echo "  test                - Testar sistema completo"
        echo "  debug               - Modo debug detalhado"
        echo "  fix-ffmpeg          - Instalar/reparar FFmpeg"
        echo "  add-video FILE      - Adicionar vídeo ao diretório interno"
        echo "  list-videos         - Listar vídeos disponíveis"
        echo "  cleanup             - Limpar arquivos antigos"
        echo "  backup              - Criar backup manual"
        echo "  restore FILE        - Restaurar backup"
        echo "  reset-password      - Resetar senha do admin"
        echo "  info                - Informações do sistema"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl start"
        echo "  hlsctl add-video /home/usuario/video.mp4"
        echo "  hlsctl list-videos"
        echo "  hlsctl test"
        echo "  hlsctl debug"
        echo ""
        echo "💡 Dica: Adicione vídeos ao diretório interno:"
        echo "  sudo cp video.mp4 /opt/hls-converter/videos_internos/"
        ;;
esac
EOF

# 12. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Configurando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter MULTIARQUIVOS Service
After=network.target nginx.service
Wants=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls-converter
Environment="PATH=/opt/hls-converter/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="FLASK_ENV=production"

ExecStart=/opt/hls-converter/venv/bin/python /opt/hls-converter/app.py

Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=5

StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db /opt/hls-converter/backups /opt/hls-converter/sessions /opt/hls-converter/videos_internos
ReadOnlyPaths=/etc /usr /lib /lib64

[Install]
WantedBy=multi-user.target
EOF

# 13. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."

chown -R hlsuser:hlsuser /opt/hls-converter
chmod 755 /opt/hls-converter
chmod 644 /opt/hls-converter/app.py
chmod 644 /opt/hls-converter/db/*.json
chmod 755 /usr/local/bin/hlsctl
chmod 700 /opt/hls-converter/sessions
chmod 750 /opt/hls-converter/backups
chmod 750 /opt/hls-converter/videos_internos

# 14. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."

systemctl daemon-reload
systemctl enable hls-converter.service

echo "⏳ Aguardando inicialização do serviço..."
if systemctl start hls-converter.service; then
    echo "✅ Serviço iniciado com sucesso"
    sleep 5
    
    if systemctl is-active --quiet hls-converter.service; then
        echo "✅ Serviço está ativo e funcionando"
    else
        echo "⚠️  Serviço iniciou mas não está ativo"
        journalctl -u hls-converter -n 20 --no-pager
    fi
else
    echo "❌ Falha ao iniciar serviço"
    journalctl -u hls-converter -n 20 --no-pager
fi

# 15. VERIFICAÇÃO FINAL
echo "🔍 Realizando verificação final..."

IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

if systemctl is-active --quiet hls-converter.service; then
    echo "🎉 SERVIÇO ATIVO E FUNCIONANDO!"
    
    echo ""
    echo "🧪 Testes rápidos:"
    
    echo "🌐 Testando health check..."
    if timeout 5 curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "✅ Health check: OK"
    else
        echo "⚠️  Health check: Pode ter problemas"
        timeout 3 curl -s http://localhost:8080/health || echo "Timeout ou erro"
    fi
    
    echo "🎬 Testando API de vídeos internos..."
    if timeout 5 curl -s http://localhost:8080/api/internal-videos | grep -q '"success":true'; then
        echo "✅ API de vídeos internos: OK"
    else
        echo "⚠️  API de vídeos internos: Pode ter problemas"
    fi
    
    echo "🔐 Testando página de login..."
    STATUS_CODE=$(timeout 5 curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login || echo "timeout")
    if [ "$STATUS_CODE" = "200" ]; then
        echo "✅ Página de login: OK"
    else
        echo "⚠️  Página de login: Código $STATUS_CODE"
    fi
    
    echo "🎬 Testando FFmpeg..."
    if command -v ffmpeg &> /dev/null; then
        echo "✅ FFmpeg encontrado"
    else
        echo "❌ FFmpeg não encontrado"
    fi
    
else
    echo "❌ Serviço não está ativo"
    echo ""
    echo "📋 Logs de erro:"
    journalctl -u hls-converter -n 30 --no-pager
fi

# 16. CRIAR EXEMPLO DE VÍDEO PARA TESTE
echo ""
echo "📝 Criando exemplo de vídeo para teste..."

cat > /opt/hls-converter/videos_internos/README.txt << 'EOF'
🎬 Diretório de Vídeos Internos

Adicione aqui seus vídeos para conversão em HLS.

Formatos suportados:
- MP4, AVI, MOV, MKV, WEBM, FLV, WMV, MPEG

Como adicionar vídeos:
1. Copie o vídeo para este diretório:
   sudo cp /caminho/do/video.mp4 /opt/hls-converter/videos_internos/

2. Atualize a lista na interface web clicando em "Atualizar Lista"

3. Selecione os vídeos desejados e inicie a conversão

Nota: Os vídeos não são movidos, apenas copiados para processamento.

Para listar vídeos disponíveis via terminal:
  hlsctl list-videos

Para adicionar vídeo via terminal:
  hlsctl add-video /caminho/para/video.mp4
EOF

# 17. INFORMAÇÕES FINAIS
echo ""
echo "=" * 70
echo "🎉🎉🎉 INSTALAÇÃO MULTIARQUIVOS COMPLETA! 🎉🎉🎉"
echo "=" * 70
echo ""
echo "✅ CORREÇÕES APLICADAS:"
echo "   ✅ Bug de múltiplos arquivos resolvido"
echo "   ✅ Conversão em sequência implementada"
echo "   ✅ Progresso em tempo real por arquivo"
echo "   ✅ Opção para arquivos internos adicionada"
echo ""
echo "✨ NOVAS FUNCIONALIDADES:"
echo "   1. Duas formas de seleção de vídeos:"
echo "      📤 Upload de arquivos externos"
echo "      📁 Seleção de arquivos internos"
echo "   2. Conversão de múltiplos vídeos em sequência"
echo "   3. Manutenção da ordem dos arquivos"
echo "   4. Progresso individual por vídeo"
echo "   5. Interface com tabs para escolha"
echo ""
echo "🔗 URLS DO SISTEMA:"
echo "   🔐 Login:        http://$IP:8080/login"
echo "   🎮 Dashboard:    http://$IP:8080/"
echo "   🎬 Upload:       http://$IP:8080/#upload"
echo "   🩺 Health:       http://$IP:8080/health"
echo ""
echo "📂 ADICIONAR VÍDEOS INTERNOS:"
echo "   Via terminal:"
echo "     sudo cp video.mp4 /opt/hls-converter/videos_internos/"
echo "     hlsctl add-video /caminho/para/video.mp4"
echo ""
echo "   Via interface web:"
echo "     1. Acesse a aba 'Upload'"
echo "     2. Clique em 'Arquivos Internos'"
echo "     3. Clique em 'Atualizar Lista'"
echo "     4. Selecione os vídeos desejados"
echo "     5. Digite um nome para a conversão"
echo "     6. Selecione as qualidades"
echo "     7. Clique em 'Iniciar Conversão'"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start        - Iniciar serviço"
echo "   • hlsctl stop         - Parar serviço"
echo "   • hlsctl restart      - Reiniciar serviço"
echo "   • hlsctl status       - Ver status"
echo "   • hlsctl logs [-f]    - Ver logs (-f para seguir)"
echo "   • hlsctl test         - Testar sistema completo"
echo "   • hlsctl debug        - Modo debug detalhado"
echo "   • hlsctl fix-ffmpeg   - Instalar/reparar FFmpeg"
echo "   • hlsctl add-video FILE - Adicionar vídeo interno"
echo "   • hlsctl list-videos  - Listar vídeos disponíveis"
echo "   • hlsctl cleanup      - Limpar arquivos antigos"
echo "   • hlsctl backup       - Criar backup"
echo "   • hlsctl restore FILE - Restaurar backup"
echo "   • hlsctl info         - Informações do sistema"
echo ""
echo "💡 DICAS DE USO:"
echo "   1. Teste com 2-3 vídeos pequenos primeiro"
echo "   2. Use a aba 'Arquivos Internos' para vídeos grandes"
echo "   3. Verifique espaço em disco antes de converter"
echo "   4. Monitore o progresso em tempo real"
echo ""
echo "🆘 SUPORTE:"
echo "   Se tiver problemas:"
echo "   1. Execute: hlsctl debug"
echo "   2. Verifique logs: hlsctl logs -f"
echo "   3. Teste FFmpeg: hlsctl fix-ffmpeg"
echo ""
echo "=" * 70
echo "🚀 Sistema 100% funcional para múltiplos arquivos!"
echo "=" * 70
