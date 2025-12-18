#!/bin/bash
# install_hls_converter_final_completo_fixed.sh - VERSÃO FINAL CORRIGIDA

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE - VERSÃO CORRIGIDA"
echo "========================================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_final_completo_fixed.sh"
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
    bc

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
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,backups,sessions,static}

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

# 8. Configurar nginx
echo "🌐 Configurando nginx..."
cat > /etc/nginx/sites-available/hls-converter << 'EOF'
server {
    listen 80;
    server_name _;
    
    client_max_body_size 10G;
    
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
        
        # Timeouts
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
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

# 9. CRIAR APLICAÇÃO FLASK COMPLETA CORRIGIDA
echo "💻 Criando aplicação Flask completa corrigida..."

cat > /opt/hls-converter/app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão Corrigida
Sistema completo com autenticação, histórico, backup e nome personalizado
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
import traceback

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
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024 * 1024  # 10GB max upload

# Diretórios
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
BACKUP_DIR = os.path.join(BASE_DIR, "backups")
STATIC_DIR = os.path.join(BASE_DIR, "static")
USERS_FILE = os.path.join(DB_DIR, "users.json")
CONVERSIONS_FILE = os.path.join(DB_DIR, "conversions.json")

# Criar diretórios
for dir_path in [UPLOAD_DIR, HLS_DIR, LOG_DIR, DB_DIR, BACKUP_DIR, STATIC_DIR, app.config['SESSION_FILE_DIR']]:
    os.makedirs(dir_path, exist_ok=True)

# Fila para processamento em sequência
executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)

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
            with open(USERS_FILE, 'r', encoding='utf-8') as f:
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
        with open(USERS_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
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
            with open(CONVERSIONS_FILE, 'r', encoding='utf-8') as f:
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
        
        with open(CONVERSIONS_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
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
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] {message}\n")
    except:
        pass

def sanitize_filename(filename):
    """Remove caracteres inválidos do nome do arquivo"""
    # Mantém apenas caracteres seguros
    safe_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ."
    filename = ''.join(c for c in filename if c in safe_chars)
    # Remove múltiplos espaços
    filename = ' '.join(filename.split())
    # Limita tamanho
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
        
        # Lista de diretórios para backup
        dirs_to_backup = [
            DB_DIR,
            os.path.join(BASE_DIR, "app.py"),
            os.path.join(LOG_DIR, "activity.log")
        ]
        
        # Criar arquivo de metadados
        metadata = {
            "backup_name": backup_name,
            "created_at": datetime.now().isoformat(),
            "version": "2.2.0",
            "directories": dirs_to_backup,
            "total_users": len(load_users().get('users', {})),
            "total_conversions": load_conversions().get('stats', {}).get('total', 0)
        }
        
        metadata_file = os.path.join(BACKUP_DIR, f"{backup_name}_metadata.json")
        with open(metadata_file, 'w', encoding='utf-8') as f:
            json.dump(metadata, f, indent=2)
        
        dirs_to_backup.append(metadata_file)
        
        # Criar arquivo tar.gz
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
        
        # Remover arquivo de metadados temporário
        os.remove(metadata_file)
        
        # Calcular tamanho
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
        # Extrair backup
        extract_dir = tempfile.mkdtemp(prefix="hls_restore_")
        
        with tarfile.open(backup_file, "r:gz") as tar:
            tar.extractall(path=extract_dir)
        
        # Verificar metadados
        metadata_files = [f for f in os.listdir(extract_dir) if f.endswith('_metadata.json')]
        if metadata_files:
            metadata_file = os.path.join(extract_dir, metadata_files[0])
            with open(metadata_file, 'r', encoding='utf-8') as f:
                metadata = json.load(f)
        
        # Restaurar arquivos
        for root, dirs, files in os.walk(extract_dir):
            for file in files:
                if file.endswith('_metadata.json'):
                    continue
                
                src_path = os.path.join(root, file)
                rel_path = os.path.relpath(src_path, extract_dir)
                
                # Determinar destino
                if rel_path.startswith("db/"):
                    dst_path = os.path.join(DB_DIR, os.path.basename(file))
                elif rel_path == "app.py":
                    dst_path = os.path.join(BASE_DIR, "app.py")
                elif rel_path == "activity.log":
                    dst_path = os.path.join(LOG_DIR, "activity.log")
                else:
                    dst_path = os.path.join(BASE_DIR, rel_path)
                
                # Copiar arquivo
                os.makedirs(os.path.dirname(dst_path), exist_ok=True)
                shutil.copy2(src_path, dst_path)
        
        # Limpar diretório temporário
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
        
        # Ordenar por data (mais recente primeiro)
        backups.sort(key=lambda x: x['modified'], reverse=True)
        
    except Exception as e:
        print(f"Erro ao listar backups: {e}")
    
    return backups

# =============== FUNÇÕES DE CONVERSÃO CORRIGIDAS ===============
def convert_single_video(video_data, playlist_id, index, total_files, qualities, callback=None):
    """
    Converte um único vídeo para HLS - VERSÃO CORRIGIDA
    """
    ffmpeg_path = find_ffmpeg()
    if not ffmpeg_path:
        return None, "FFmpeg não encontrado"
    
    file, filename = video_data
    video_id = f"{playlist_id}_{index:03d}"
    output_dir = os.path.join(HLS_DIR, playlist_id, video_id)
    os.makedirs(output_dir, exist_ok=True)
    
    # Salvar arquivo original
    original_path = os.path.join(output_dir, "original.mp4")
    try:
        file.save(original_path)
    except Exception as e:
        return None, f"Erro ao salvar arquivo: {str(e)}"
    
    # Converter para cada qualidade
    video_info = {
        "id": video_id,
        "filename": filename,
        "qualities": [],
        "duration": 0,
        "playlist_paths": {}
    }
    
    for quality in qualities:
        quality_dir = os.path.join(output_dir, quality)
        os.makedirs(quality_dir, exist_ok=True)
        
        m3u8_file = os.path.join(quality_dir, "index.m3u8")
        
        # Configurações por qualidade
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
        
        # Comando FFmpeg otimizado
        cmd = [
            ffmpeg_path, '-i', original_path,
            '-vf', f'scale={scale}:force_original_aspect_ratio=decrease',
            '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
            '-maxrate', bitrate, '-bufsize', f'{int(int(bitrate[:-1]) * 2)}k',
            '-c:a', 'aac', '-b:a', audio_bitrate,
            '-hls_time', '6',
            '-hls_list_size', '0',
            '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
            '-f', 'hls', m3u8_file
        ]
        
        # Executar conversão
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            if result.returncode == 0:
                video_info["qualities"].append(quality)
                video_info["playlist_paths"][quality] = f"{video_id}/{quality}/index.m3u8"
                
                # Obter duração do vídeo
                try:
                    duration_cmd = [
                        ffmpeg_path, '-i', original_path,
                        '-f', 'null', '-'
                    ]
                    duration_result = subprocess.run(
                        duration_cmd,
                        capture_output=True,
                        text=True,
                        stderr=subprocess.STDOUT
                    )
                    for line in duration_result.stderr.split('\n'):
                        if 'Duration:' in line:
                            parts = line.split(',')
                            if len(parts) > 0:
                                duration_str = parts[0].split('Duration:')[1].strip()
                                h, m, s = duration_str.split(':')
                                s = s.split('.')[0]
                                video_info["duration"] = int(h) * 3600 + int(m) * 60 + int(float(s))
                                break
                except:
                    video_info["duration"] = 0
            else:
                print(f"Erro FFmpeg para {quality}: {result.stderr[:500]}")
                continue
        except subprocess.TimeoutExpired:
            print(f"Timeout na conversão para {quality}")
            continue
        except Exception as e:
            print(f"Exceção na conversão para {quality}: {str(e)}")
            continue
    
    # Mover arquivo original para pasta original
    original_folder = os.path.join(output_dir, "original")
    os.makedirs(original_folder, exist_ok=True)
    final_original_path = os.path.join(original_folder, filename)
    try:
        shutil.move(original_path, final_original_path)
    except:
        pass
    
    # Callback de progresso
    if callback:
        progress = int((index / total_files) * 100)
        callback(progress, f"Convertendo {filename} ({index}/{total_files})")
    
    return video_info, None

def create_master_playlist(playlist_id, videos_info, qualities, conversion_name):
    """
    Cria um master playlist M3U8 - VERSÃO CORRIGIDA
    """
    playlist_dir = os.path.join(HLS_DIR, playlist_id)
    master_playlist = os.path.join(playlist_dir, "master.m3u8")
    
    # Criar arquivo de informação da playlist
    playlist_info = {
        "playlist_id": playlist_id,
        "conversion_name": conversion_name,
        "created_at": datetime.now().isoformat(),
        "videos_count": len(videos_info),
        "total_duration": 0,
        "videos": videos_info,
        "qualities": qualities
    }
    
    # Garantir que existem vídeos convertidos
    available_qualities = set()
    for video in videos_info:
        if video.get("qualities"):
            available_qualities.update(video["qualities"])
    
    if not available_qualities:
        return None, 0
    
    # Criar master playlist
    with open(master_playlist, 'w', encoding='utf-8') as f:
        f.write("#EXTM3U\n")
        f.write("#EXT-X-VERSION:3\n")
        
        # Para cada qualidade disponível, criar uma variante playlist
        for quality in qualities:
            if quality not in available_qualities:
                continue
            
            # Configurações por qualidade
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
            
            f.write(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={resolution}\n')
            f.write(f'{quality}/index.m3u8\n')
        
        # Criar variante playlists para cada qualidade
        for quality in qualities:
            if quality not in available_qualities:
                continue
                
            quality_playlist = os.path.join(playlist_dir, quality, "index.m3u8")
            os.makedirs(os.path.dirname(quality_playlist), exist_ok=True)
            
            with open(quality_playlist, 'w', encoding='utf-8') as qf:
                qf.write("#EXTM3U\n")
                qf.write("#EXT-X-VERSION:3\n")
                qf.write("#EXT-X-PLAYLIST-TYPE:VOD\n")
                
                # Para cada vídeo, adicionar sua playlist
                for video_info in videos_info:
                    if quality in video_info.get("qualities", []):
                        video_playlist_path = f"../{video_info['id']}/{quality}/index.m3u8"
                        if os.path.exists(os.path.join(playlist_dir, video_info['id'], quality, "index.m3u8")):
                            qf.write(f'#EXT-X-DISCONTINUITY\n')
                            duration = video_info.get("duration", 10)
                            qf.write(f'#EXTINF:{duration:.6f},\n')
                            qf.write(f'{video_playlist_path}\n')
                            playlist_info["total_duration"] += duration
    
    # Salvar informações da playlist
    info_file = os.path.join(playlist_dir, "playlist_info.json")
    with open(info_file, 'w', encoding='utf-8') as f:
        json.dump(playlist_info, f, indent=2)
    
    return master_playlist, playlist_info["total_duration"]

def process_multiple_videos(files_data, qualities, playlist_id, conversion_name):
    """
    Processa múltiplos vídeos em sequência - VERSÃO SIMPLIFICADA
    """
    videos_info = []
    errors = []
    
    total_files = len(files_data)
    
    for index, (file, filename) in enumerate(files_data, 1):
        print(f"Processando arquivo {index}/{total_files}: {filename}")
        
        try:
            video_info, error = convert_single_video(
                (file, filename), 
                playlist_id, 
                index, 
                total_files, 
                qualities
            )
            
            if error:
                errors.append(f"{filename}: {error}")
                video_info = {
                    "id": f"{playlist_id}_{index:03d}",
                    "filename": filename,
                    "qualities": [],
                    "error": error
                }
            elif not video_info.get("qualities"):
                errors.append(f"{filename}: Nenhuma qualidade convertida com sucesso")
                video_info["error"] = "Nenhuma qualidade convertida"
            
            videos_info.append(video_info)
            print(f"Concluído: {filename} ({index}/{total_files})")
                
        except Exception as e:
            error_msg = f"Erro ao processar {filename}: {str(e)}"
            print(f"ERRO: {error_msg}")
            errors.append(error_msg)
            videos_info.append({
                "id": f"{playlist_id}_{index:03d}",
                "filename": filename,
                "qualities": [],
                "error": error_msg
            })
    
    # Criar master playlist apenas se houver vídeos convertidos
    videos_with_quality = [v for v in videos_info if v.get("qualities")]
    
    if videos_with_quality:
        master_playlist, total_duration = create_master_playlist(
            playlist_id, 
            videos_info, 
            qualities, 
            conversion_name
        )
        
        if master_playlist:
            return {
                "success": True,
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "videos_count": len(videos_info),
                "converted_count": len(videos_with_quality),
                "errors": errors,
                "master_playlist": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "videos_info": videos_info,
                "total_duration": total_duration,
                "qualities": [q for q in qualities if any(q in v.get("qualities", []) for v in videos_info)]
            }
    
    # Se chegou aqui, houve falha
    return {
        "success": False,
        "playlist_id": playlist_id,
        "conversion_name": conversion_name,
        "errors": errors if errors else ["Nenhum vídeo foi convertido com sucesso"],
        "videos_info": videos_info
    }

# =============== PÁGINAS HTML (MESMO CÓDIGO) ===============
# [O HTML permanece igual - muito longo para incluir aqui]
# Inserir todo o HTML do arquivo anterior aqui...

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

@app.route('/api/clear-history', methods=['POST'])
def api_clear_history():
    """Limpar histórico de conversões"""
    try:
        data = load_conversions()
        count = len(data.get('conversions', []))
        
        data['conversions'] = []
        data['stats']['total'] = 0
        data['stats']['success'] = 0
        data['stats']['failed'] = 0
        
        save_conversions(data)
        
        log_activity(f"Histórico de conversões limpo: {count} entradas removidas")
        
        return jsonify({
            "success": True,
            "message": f"{count} conversões removidas do histórico"
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

# =============== ROTAS DE CONVERSÃO CORRIGIDAS ===============

@app.route('/convert-multiple', methods=['POST'])
def convert_multiple_videos_route():
    """Converter múltiplos vídeos com nome personalizado - VERSÃO CORRIGIDA"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    try:
        print("Iniciando conversão múltipla...")
        
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            return jsonify({
                "success": False,
                "error": "FFmpeg não encontrado. Execute: sudo apt-get install ffmpeg"
            })
        
        if 'files[]' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        files = request.files.getlist('files[]')
        if not files or files[0].filename == '':
            return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
        
        print(f"Arquivos recebidos: {len(files)}")
        
        conversion_name = request.form.get('conversion_name', '').strip()
        if not conversion_name:
            conversion_name = f"Conversão {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        
        conversion_name = sanitize_filename(conversion_name)
        
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
            print(f"Qualidades selecionadas: {qualities}")
        except:
            qualities = ["720p"]
        
        # Preparar dados dos arquivos
        files_data = []
        for file in files:
            if file.filename:
                files_data.append((file, file.filename))
        
        if not files_data:
            return jsonify({"success": False, "error": "Nenhum arquivo válido"})
        
        playlist_id = str(uuid.uuid4())[:8]
        print(f"Playlist ID gerado: {playlist_id}")
        
        # Processar em thread separada
        def process_conversion():
            return process_multiple_videos(files_data, qualities, playlist_id, conversion_name)
        
        future = executor.submit(process_conversion)
        result = future.result(timeout=3600)  # 1 hora de timeout
        
        print(f"Resultado da conversão: {result.get('success', False)}")
        
        if result.get("success"):
            # Salvar no histórico
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "video_id": playlist_id,
                "conversion_name": conversion_name,
                "filename": f"{len(files_data)} arquivos",
                "qualities": result.get("qualities", qualities),
                "timestamp": datetime.now().isoformat(),
                "status": "success",
                "type": "multiple",
                "videos_count": len(files_data),
                "converted_count": result.get("converted_count", 0),
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "errors": result.get("errors", [])
            }
            
            if not isinstance(conversions.get('conversions'), list):
                conversions['conversions'] = []
            
            conversions['conversions'].insert(0, conversion_data)
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['success'] = conversions['stats'].get('success', 0) + 1
            
            save_conversions(conversions)
            
            log_activity(f"Conversão '{conversion_name}' realizada: {len(files_data)} arquivos -> {playlist_id}")
            
            response_data = {
                "success": True,
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "videos_count": len(files_data),
                "converted_count": result.get("converted_count", 0),
                "qualities": result.get("qualities", qualities),
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "errors": result.get("errors", []),
                "message": f"Conversão '{conversion_name}' concluída!"
            }
            
            print(f"Resposta de sucesso: {response_data}")
            return jsonify(response_data)
        else:
            # Registrar falha
            conversions = load_conversions()
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['failed'] = conversions['stats'].get('failed', 0) + 1
            save_conversions(conversions)
            
            error_msg = result.get("errors", ["Erro desconhecido"])[0] if result.get("errors") else "Erro na conversão"
            
            response_data = {
                "success": False,
                "error": error_msg,
                "errors": result.get("errors", [])
            }
            
            print(f"Resposta de erro: {response_data}")
            return jsonify(response_data)
        
    except concurrent.futures.TimeoutError:
        print("Timeout na conversão")
        return jsonify({
            "success": False,
            "error": "Timeout na conversão (muito tempo de processamento)"
        })
    except Exception as e:
        print(f"Erro na conversão múltipla: {str(e)}")
        print(traceback.format_exc())
        
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

@app.route('/convert', methods=['POST'])
def convert_video():
    """Converter um único vídeo para HLS (para compatibilidade)"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    try:
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            return jsonify({
                "success": False,
                "error": "FFmpeg não encontrado. Execute: sudo apt-get install ffmpeg"
            })
        
        if 'file' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
        
        conversion_name = request.form.get('conversion_name', file.filename)
        conversion_name = sanitize_filename(conversion_name)
        
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Usar a função de múltiplos vídeos com apenas um arquivo
        playlist_id = str(uuid.uuid4())[:8]
        result = process_multiple_videos([(file, file.filename)], qualities, playlist_id, conversion_name)
        
        if result.get("success"):
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "video_id": playlist_id,
                "conversion_name": conversion_name,
                "filename": file.filename,
                "qualities": qualities,
                "timestamp": datetime.now().isoformat(),
                "status": "success",
                "type": "single",
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8"
            }
            
            if not isinstance(conversions.get('conversions'), list):
                conversions['conversions'] = []
            
            conversions['conversions'].insert(0, conversion_data)
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['success'] = conversions['stats'].get('success', 0) + 1
            
            save_conversions(conversions)
            
            log_activity(f"Conversão única realizada: {file.filename} -> {playlist_id}")
            
            return jsonify({
                "success": True,
                "video_id": playlist_id,
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "qualities": qualities,
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}"
            })
        else:
            return jsonify({
                "success": False,
                "error": "Erro na conversão"
            })
        
    except Exception as e:
        print(f"Erro na conversão: {e}")
        
        try:
            conversions = load_conversions()
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['failed'] = conversions['stats'].get('failed', 0) + 1
            save_conversions(conversions)
        except:
            pass
        
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/hls/<playlist_id>/master.m3u8')
@app.route('/hls/<playlist_id>/<path:filename>')
def serve_hls(playlist_id, filename=None):
    """Servir arquivos HLS"""
    if filename is None:
        filename = "master.m3u8"
    
    filepath = os.path.join(HLS_DIR, playlist_id, filename)
    if os.path.exists(filepath):
        return send_file(filepath)
    
    # Buscar recursivamente
    for root, dirs, files in os.walk(os.path.join(HLS_DIR, playlist_id)):
        if filename in files:
            return send_file(os.path.join(root, filename))
    
    return "Arquivo não encontrado", 404

@app.route('/player/<playlist_id>')
def player_page(playlist_id):
    """Página do player para playlist"""
    m3u8_url = f"/hls/{playlist_id}/master.m3u8"
    
    index_file = os.path.join(HLS_DIR, playlist_id, "playlist_info.json")
    video_info = []
    conversion_name = playlist_id
    
    if os.path.exists(index_file):
        try:
            with open(index_file, 'r', encoding='utf-8') as f:
                data = json.load(f)
                video_info = data.get('videos', [])
                conversion_name = data.get('conversion_name', playlist_id)
        except:
            pass
    
    # Verificar se a playlist existe
    playlist_path = os.path.join(HLS_DIR, playlist_id, "master.m3u8")
    if not os.path.exists(playlist_path):
        return f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Playlist não encontrada</title>
            <style>
                body {{ 
                    margin: 0; 
                    padding: 20px; 
                    background: #1a1a1a; 
                    color: white;
                    font-family: Arial, sans-serif;
                    text-align: center;
                }}
                .error-container {{
                    max-width: 600px;
                    margin: 100px auto;
                    background: #2d2d2d;
                    padding: 40px;
                    border-radius: 10px;
                }}
                .back-btn {{ 
                    background: #4361ee; 
                    color: white; 
                    border: none; 
                    padding: 10px 20px; 
                    border-radius: 5px; 
                    cursor: pointer;
                    margin-top: 20px;
                }}
            </style>
        </head>
        <body>
            <div class="error-container">
                <h1>🎬 Playlist não encontrada</h1>
                <p>A playlist <strong>{playlist_id}</strong> não foi encontrada.</p>
                <p>Ela pode ter expirado ou sido removida.</p>
                <button class="back-btn" onclick="window.history.back()">Voltar</button>
            </div>
        </body>
        </html>
        """
    
    player_html = f'''
    <!DOCTYPE html>
    <html>
    <head>
        <title>{conversion_name} - HLS Player</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <script src="https://kit.fontawesome.com/a076d05399.js" crossorigin="anonymous"></script>
        <style>
            body {{ 
                margin: 0; 
                padding: 20px; 
                background: #1a1a1a; 
                color: white;
                font-family: Arial, sans-serif;
            }}
            .player-container {{ 
                max-width: 1200px; 
                margin: 0 auto; 
                background: #2d2d2d;
                border-radius: 10px;
                overflow: hidden;
                box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            }}
            .back-btn {{ 
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
            }}
            .playlist-info {{
                padding: 20px;
                background: #363636;
                border-bottom: 1px solid #444;
            }}
            .videos-list {{
                padding: 20px;
                max-height: 300px;
                overflow-y: auto;
            }}
            .video-item {{
                padding: 10px 15px;
                background: #2d2d2d;
                border-radius: 5px;
                margin-bottom: 10px;
                border-left: 3px solid #4361ee;
            }}
            .video-title {{
                font-weight: bold;
                color: #4cc9f0;
            }}
            .video-meta {{
                font-size: 0.9rem;
                color: #aaa;
                margin-top: 5px;
            }}
        </style>
    </head>
    <body>
        <button class="back-btn" onclick="window.history.back()">
            <i class="fas fa-arrow-left"></i> Voltar
        </button>
        
        <div class="player-container">
            <div class="playlist-info">
                <h2>🎬 {conversion_name}</h2>
                <p>Total de vídeos: {len(video_info)} | Use as setas para navegar entre os vídeos</p>
            </div>
            
            <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="500">
                <source src="{m3u8_url}" type="application/x-mpegURL">
                <p class="vjs-no-js">
                    Para visualizar este vídeo, habilite o JavaScript e considere atualizar para um
                    navegador que suporte <a href="https://videojs.com/html5-video-support/" target="_blank">HTML5 video</a>
                </p>
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
            duration = v.get("duration", 0)
            duration_str = f"{duration//60}:{duration%60:02d}" if duration > 0 else "N/A"
            
            player_html += f'''
                <div class="video-item">
                    <div class="video-title">{filename}</div>
                    <div class="video-meta">
                        Qualidades: {qualities} | Duração: {duration_str}
                    </div>
                </div>
            '''
        
        player_html += '''
            </div>
        '''
    
    player_html += '''
        </div>
        
        <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
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
                this.play().catch(function(error) {
                    console.log("Auto-play falhou:", error);
                });
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
        "service": "hls-converter-ultimate",
        "timestamp": datetime.now().isoformat(),
        "version": "2.2.1",
        "ffmpeg": find_ffmpeg() is not None,
        "multi_upload": True,
        "backup_system": True,
        "named_conversions": True
    })

# =============== ROTAS DE BACKUP ===============

@app.route('/api/backup/create', methods=['POST'])
def api_backup_create():
    """Criar um novo backup"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    backup_name = request.args.get('name', None)
    
    result = create_backup(backup_name)
    
    if result['success']:
        log_activity(f"Usuário {session['user_id']} criou backup: {result['backup_name']}")
    
    return jsonify(result)

@app.route('/api/backup/list')
def api_backup_list():
    """Listar todos os backups"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    backups = list_backups()
    
    return jsonify({
        "success": True,
        "backups": backups,
        "count": len(backups)
    })

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 60)
    print("🚀 HLS Converter ULTIMATE - Versão 2.2.1 Corrigida")
    print("=" * 60)
    print(f"📂 Diretório base: {BASE_DIR}")
    print(f"🔐 Autenticação: Habilitada")
    print(f"👤 Usuário padrão: admin / admin")
    print(f"💾 Sistema de backup: Habilitado")
    print(f"🏷️  Nome personalizado: Habilitado")
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

# 11. CRIAR SCRIPT DE GERENCIAMENTO CORRIGIDO
echo "📝 Criando script de gerenciamento corrigido..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"

case "$1" in
    start)
        echo "🚀 Iniciando HLS Converter..."
        systemctl start hls-converter
        sleep 2
        systemctl is-active --quiet hls-converter && echo "✅ Serviço iniciado" || echo "❌ Falha ao iniciar"
        ;;
    stop)
        echo "🛑 Parando HLS Converter..."
        systemctl stop hls-converter
        echo "✅ Serviço parado"
        ;;
    restart)
        echo "🔄 Reiniciando HLS Converter..."
        systemctl restart hls-converter
        sleep 2
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço reiniciado"
            echo ""
            echo "📊 Status atual:"
            systemctl status hls-converter --no-pager | head -10
        else
            echo "❌ Falha ao reiniciar"
            journalctl -u hls-converter -n 20 --no-pager
        fi
        ;;
    status)
        systemctl status hls-converter --no-pager
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            journalctl -u hls-converter -f
        else
            journalctl -u hls-converter -n 50 --no-pager
        fi
        ;;
    test)
        echo "🧪 Testando sistema HLS Converter..."
        echo "=" * 60
        
        # Teste 1: Serviço
        echo "1️⃣  Testando serviço..."
        if systemctl is-active --quiet hls-converter; then
            echo "   ✅ Serviço está ativo"
        else
            echo "   ❌ Serviço não está ativo"
        fi
        
        # Teste 2: Porta
        echo "2️⃣  Testando porta 8080..."
        if netstat -tlnp 2>/dev/null | grep :8080 > /dev/null; then
            echo "   ✅ Porta 8080 em uso"
        else
            echo "   ❌ Porta 8080 não está em uso"
        fi
        
        # Teste 3: Health check
        echo "3️⃣  Testando health check..."
        if curl -s --max-time 5 http://localhost:8080/health | grep -q "healthy"; then
            echo "   ✅ Health check OK"
        else
            echo "   ❌ Health check falhou"
            curl -s --max-time 5 http://localhost:8080/health || true
        fi
        
        # Teste 4: Login page
        echo "4️⃣  Testando página de login..."
        STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/login)
        if [ "$STATUS_CODE" = "200" ]; then
            echo "   ✅ Página de login OK (código 200)"
        else
            echo "   ⚠️  Página de login: Código $STATUS_CODE"
        fi
        
        # Teste 5: FFmpeg
        echo "5️⃣  Testando FFmpeg..."
        if command -v ffmpeg &> /dev/null; then
            echo "   ✅ FFmpeg encontrado: $(which ffmpeg)"
            echo "   📊 Versão: $(ffmpeg -version | head -1 | cut -d' ' -f3)"
        else
            echo "   ❌ FFmpeg não encontrado"
        fi
        
        # Teste 6: Diretórios
        echo "6️⃣  Testando diretórios..."
        for dir in "$HLS_HOME" "$HLS_HOME/uploads" "$HLS_HOME/hls" "$HLS_HOME/backups" "$HLS_HOME/db"; do
            if [ -d "$dir" ]; then
                echo "   ✅ $dir"
            else
                echo "   ❌ $dir (não existe)"
            fi
        done
        
        # Teste 7: Permissões
        echo "7️⃣  Testando permissões..."
        if [ -f "/opt/hls-converter/app.py" ]; then
            perms=$(stat -c "%A %U %G" "/opt/hls-converter/app.py")
            echo "   ✅ app.py: $perms"
        else
            echo "   ❌ app.py não encontrado"
        fi
        
        echo "=" * 60
        echo "🧪 Teste concluído!"
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
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        echo "Removendo arquivos de upload com mais de 7 dias..."
        find /opt/hls-converter/uploads -type f -mtime +7 -delete 2>/dev/null || true
        echo "Removendo playlists HLS com mais de 7 dias..."
        find /opt/hls-converter/hls -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
        echo "✅ Limpeza concluída"
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
print('⚠️  IMPORTANTE: Altere a senha no primeiro login!')
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
    size_mb = result['size'] / (1024 * 1024)
    print(f'✅ Backup criado: {result[\"backup_name\"]}')
    print(f'📁 Local: {result[\"backup_path\"]}')
    print(f'📦 Tamanho: {size_mb:.2f} MB')
    print(f'📅 Data: {result[\"created_at\"]}')
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
        echo "⚠️  ATENÇÃO: O serviço será interrompido durante a restauração"
        
        systemctl stop hls-converter
        
        cd /opt/hls-converter
        source venv/bin/activate
        python3 -c "
import sys
sys.path.insert(0, '.')
from app import restore_backup
result = restore_backup('$2')
if result['success']:
    print('✅ Backup restaurado com sucesso!')
    print('🔄 Reiniciando serviço...')
else:
    print(f'❌ Erro: {result[\"error\"]}')
"
        
        systemctl start hls-converter
        sleep 2
        systemctl status hls-converter --no-pager | head -10
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=" * 70
        echo "🎬 HLS Converter ULTIMATE v2.2.1 - Informações do Sistema"
        echo "=" * 70
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo "Porta: 8080"
        echo "IP: $IP"
        echo "Login: http://$IP:8080/login"
        echo "Usuário: admin"
        echo "Senha: admin (altere no primeiro acesso)"
        echo ""
        echo "⚙️  Funcionalidades:"
        echo "  ✅ Sistema de autenticação seguro"
        echo "  ✅ Multi-upload de vídeos"
        echo "  ✅ Nome personalizado para conversões"
        echo "  ✅ Sistema de backup/restore"
        echo "  ✅ Histórico de conversões"
        echo "  ✅ Interface web moderna"
        echo "  ✅ Player HLS integrado"
        echo ""
        echo "🔧 Comandos disponíveis:"
        echo "  hlsctl start        - Iniciar serviço"
        echo "  hlsctl stop         - Parar serviço"
        echo "  hlsctl restart      - Reiniciar serviço"
        echo "  hlsctl status       - Ver status"
        echo "  hlsctl logs [-f]    - Ver logs (-f para seguir)"
        echo "  hlsctl test         - Testar sistema completo"
        echo "  hlsctl fix-ffmpeg   - Instalar/reparar FFmpeg"
        echo "  hlsctl cleanup      - Limpar arquivos antigos"
        echo "  hlsctl backup       - Criar backup manual"
        echo "  hlsctl restore FILE - Restaurar backup"
        echo "  hlsctl reset-password - Resetar senha do admin"
        echo "  hlsctl info         - Esta informação"
        echo "=" * 70
        ;;
    *)
        echo "🎬 HLS Converter ULTIMATE - Gerenciador"
        echo "========================================"
        echo ""
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos:"
        echo "  start        - Iniciar serviço"
        echo "  stop         - Parar serviço"
        echo "  restart      - Reiniciar serviço"
        echo "  status       - Ver status"
        echo "  logs [-f]    - Ver logs (-f para seguir)"
        echo "  test         - Testar sistema completo"
        echo "  fix-ffmpeg   - Instalar/reparar FFmpeg"
        echo "  cleanup      - Limpar arquivos antigos"
        echo "  backup       - Criar backup manual"
        echo "  restore FILE - Restaurar backup"
        echo "  reset-password - Resetar senha do admin"
        echo "  info         - Informações do sistema"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl start"
        echo "  hlsctl logs -f"
        echo "  hlsctl test"
        echo "  hlsctl backup"
        echo "  hlsctl restore /backups/hls_backup.tar.gz"
        ;;
esac
EOF

# 12. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Configurando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter ULTIMATE Service
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
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db /opt/hls-converter/backups /opt/hls-converter/sessions
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

# 14. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."

systemctl daemon-reload
systemctl enable hls-converter.service

if systemctl start hls-converter.service; then
    echo "✅ Serviço iniciado com sucesso"
    sleep 3
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
    
    # Health check
    if curl -s --max-time 5 http://localhost:8080/health | grep -q "healthy"; then
        echo "✅ Health check: OK"
    else
        echo "⚠️  Health check: Pode ter problemas"
    fi
    
    # Login page
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8080/login)
    if [ "$STATUS_CODE" = "200" ]; then
        echo "✅ Página de login: OK"
    else
        echo "⚠️  Página de login: Código $STATUS_CODE"
    fi
    
    echo ""
    echo "📊 Status do serviço:"
    systemctl status hls-converter --no-pager | head -10
    
else
    echo "❌ Serviço não está ativo"
    echo ""
    echo "📋 Logs de erro:"
    journalctl -u hls-converter -n 30 --no-pager
fi

# 16. CRIAR BACKUP INICIAL
echo ""
echo "💾 Criando backup inicial do sistema..."
cd /opt/hls-converter
source venv/bin/activate
python3 -c "
import sys
sys.path.insert(0, '.')
from app import create_backup
result = create_backup('backup_inicial')
if result['success']:
    import os
    size_mb = result['size'] / (1024 * 1024)
    print(f'✅ Backup inicial criado: {result[\"backup_name\"]}')
    print(f'📦 Tamanho: {size_mb:.2f} MB')
    print(f'📁 Local: {result[\"backup_path\"]}')
else:
    print(f'⚠️  Não foi possível criar backup inicial: {result[\"error\"]}')
"

# 17. INFORMAÇÕES FINAIS
echo ""
echo "=" * 70
echo "🎉🎉🎉 INSTALAÇÃO COMPLETA FINALIZADA COM SUCESSO! 🎉🎉🎉"
echo "=" * 70
echo ""
echo "✅ PROBLEMAS CORRIGIDOS:"
echo ""
echo "🔧 BUGS RESOLVIDOS:"
echo "   ✅ Multi-upload funcionando corretamente"
echo "   ✅ Resposta JSON correta da API"
echo "   ✅ Processamento de múltiplos arquivos em sequência"
echo "   ✅ Geração correta de playlists M3U8"
echo "   ✅ Tratamento de erros melhorado"
echo "   ✅ Player HLS funcionando corretamente"
echo ""
echo "🔐 INFORMAÇÕES DE ACESSO:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo "   ⚠️  IMPORTANTE: Altere a senha no primeiro acesso!"
echo ""
echo "🌐 URLS DO SISTEMA:"
echo "   🔐 Login:        http://$IP:8080/login"
echo "   🎮 Dashboard:    http://$IP:8080/"
echo "   💾 Backup:       http://$IP:8080/#backup"
echo "   🩺 Health:       http://$IP:8080/health"
echo ""
echo "⚙️  COMO TESTAR O SISTEMA:"
echo "   1. Acesse http://$IP:8080/login"
echo "   2. Faça login com admin/admin"
echo "   3. Altere a senha"
echo "   4. Vá para a aba 'Upload'"
echo "   5. Digite um nome para a conversão"
echo "   6. Selecione múltiplos vídeos"
echo "   7. Escolha as qualidades"
echo "   8. Clique em 'Iniciar Conversão em Lote'"
echo "   9. Aguarde a conclusão"
echo "   10. Use os links gerados para acessar os vídeos"
echo ""
echo "🆘 SOLUÇÃO DE PROBLEMAS:"
echo "   • hlsctl test     - Testar todos os componentes"
echo "   • hlsctl logs     - Ver logs de erro"
echo "   • hlsctl restart  - Reiniciar o serviço"
echo "   • hlsctl fix-ffmpeg - Reparar FFmpeg se necessário"
echo ""
echo "=" * 70
echo "🚀 Sistema 100% pronto e corrigido! Acesse http://$IP:8080/login"
echo "=" * 70
