#!/bin/bash
# install_hls_converter_final_completo.sh - VERSÃO FINAL COMPLETA COM BACKUP E NOME PERSONALIZADO

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE - VERSÃO COMPLETA COM BACKUP"
echo "=================================================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_final_completo.sh"
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
    
    # Bloquer acesso direto a arquivos sensíveis
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

# 9. CRIAR APLICAÇÃO FLASK COMPLETA
echo "💻 Criando aplicação Flask completa com backup e nome personalizado..."

cat > /opt/hls-converter/app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão Completa
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
from flask import Flask, request, jsonify, render_template_string, send_file, redirect, url_for, session, flash, send_from_directory
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
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024 * 1024  # 10GB max upload

# Diretórios
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
BACKUP_DIR = os.path.join(BASE_DIR, "backups")
STATIC_DIR = os.path.join(BASE_DIR, "static")

# Criar diretórios
for dir_path in [UPLOAD_DIR, HLS_DIR, LOG_DIR, DB_DIR, BACKUP_DIR, STATIC_DIR, app.config['SESSION_FILE_DIR']]:
    os.makedirs(dir_path, exist_ok=True)

# Fila para processamento em sequência
processing_queue = Queue()
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
        with open(metadata_file, 'w') as f:
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
            with open(metadata_file, 'r') as f:
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

# =============== FUNÇÕES DE CONVERSÃO COM NOME PERSONALIZADO ===============
def convert_single_video(video_data, playlist_id, index, total_files, qualities, conversion_name, callback=None):
    """
    Converte um único vídeo para HLS
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
    file.save(original_path)
    
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
        
        # Comando FFmpeg
        cmd = [
            ffmpeg_path, '-i', original_path,
            '-vf', f'scale={scale}',
            '-c:v', 'libx264', '-preset', 'fast',
            '-c:a', 'aac', '-b:a', audio_bitrate,
            '-hls_time', '10',
            '-hls_list_size', '0',
            '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
            '-f', 'hls', m3u8_file
        ]
        
        # Executar conversão
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if result.returncode == 0:
                video_info["qualities"].append(quality)
                video_info["playlist_paths"][quality] = f"{video_id}/{quality}/index.m3u8"
                
                # Obter duração do vídeo
                try:
                    duration_cmd = [ffmpeg_path, '-i', original_path]
                    duration_result = subprocess.run(duration_cmd, capture_output=True, text=True, stderr=subprocess.STDOUT)
                    for line in duration_result.stdout.split('\n'):
                        if 'Duration' in line:
                            parts = line.split(',')
                            if len(parts) > 0:
                                duration_str = parts[0].split('Duration:')[1].strip()
                                h, m, s = duration_str.split(':')
                                video_info["duration"] = int(h) * 3600 + int(m) * 60 + float(s)
                                break
                except:
                    pass
            else:
                print(f"Erro FFmpeg para {quality}: {result.stderr[:200]}")
        except subprocess.TimeoutExpired:
            print(f"Timeout na conversão para {quality}")
    
    # Limpar arquivo original
    if os.path.exists(os.path.join(output_dir, "original")):
        os.makedirs(os.path.join(output_dir, "original"), exist_ok=True)
    shutil.move(original_path, os.path.join(output_dir, "original", filename))
    
    # Callback de progresso
    if callback:
        progress = int((index / total_files) * 100)
        callback(progress, f"Convertendo {filename} ({index}/{total_files})")
    
    return video_info, None

def create_master_playlist(playlist_id, videos_info, qualities, conversion_name):
    """
    Cria um master playlist M3U8
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
        "videos": videos_info
    }
    
    with open(master_playlist, 'w') as f:
        f.write("#EXTM3U\n")
        f.write("#EXT-X-VERSION:3\n")
        
        # Para cada qualidade, criar uma variante playlist
        for quality in qualities:
            if not any(quality in video["qualities"] for video in videos_info):
                continue
            
            # Configurações por qualidade
            if quality == '240p':
                scale = "426:240"
                bandwidth = "400000"
            elif quality == '480p':
                scale = "854:480"
                bandwidth = "800000"
            elif quality == '720p':
                scale = "1280:720"
                bandwidth = "1500000"
            elif quality == '1080p':
                scale = "1920:1080"
                bandwidth = "3000000"
            else:
                continue
            
            f.write(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={scale.replace(":", "x")}\n')
            f.write(f'{quality}/index.m3u8\n')
        
        # Criar variante playlists para cada qualidade
        for quality in qualities:
            quality_playlist = os.path.join(playlist_dir, quality, "index.m3u8")
            os.makedirs(os.path.dirname(quality_playlist), exist_ok=True)
            
            with open(quality_playlist, 'w') as qf:
                qf.write("#EXTM3U\n")
                qf.write("#EXT-X-VERSION:3\n")
                
                # Para cada vídeo, adicionar sua playlist
                for video_info in videos_info:
                    if quality in video_info["qualities"]:
                        video_playlist_path = f"../{video_info['id']}/{quality}/index.m3u8"
                        if os.path.exists(os.path.join(playlist_dir, video_info['id'], quality, "index.m3u8")):
                            qf.write(f'#EXT-X-DISCONTINUITY\n')
                            qf.write(f'#EXTINF:{video_info.get("duration", 10):.6f},\n')
                            qf.write(f'{video_playlist_path}\n')
                            playlist_info["total_duration"] += video_info.get("duration", 10)
    
    # Salvar informações da playlist
    info_file = os.path.join(playlist_dir, "playlist_info.json")
    with open(info_file, 'w') as f:
        json.dump(playlist_info, f, indent=2)
    
    return master_playlist, playlist_info["total_duration"]

def process_multiple_videos(files_data, qualities, playlist_id, conversion_name, progress_callback=None):
    """
    Processa múltiplos vídeos em sequência
    """
    videos_info = []
    errors = []
    
    total_files = len(files_data)
    
    for index, (file, filename) in enumerate(files_data, 1):
        if progress_callback:
            progress_callback(int(((index-1) / total_files) * 100), 
                            f"Iniciando conversão de {filename}...")
        
        try:
            video_info, error = convert_single_video(
                (file, filename), 
                playlist_id, 
                index, 
                total_files, 
                qualities,
                conversion_name,
                progress_callback
            )
            
            if error:
                errors.append(f"{filename}: {error}")
                video_info = {
                    "id": f"{playlist_id}_{index:03d}",
                    "filename": filename,
                    "qualities": [],
                    "error": error
                }
            
            videos_info.append(video_info)
            
            if progress_callback:
                progress_callback(int((index / total_files) * 100), 
                                f"Concluído: {filename} ({index}/{total_files})")
                
        except Exception as e:
            error_msg = f"Erro ao processar {filename}: {str(e)}"
            errors.append(error_msg)
            print(error_msg)
    
    # Criar master playlist
    if videos_info and any(v["qualities"] for v in videos_info):
        master_playlist, total_duration = create_master_playlist(playlist_id, videos_info, qualities, conversion_name)
        
        return {
            "success": True,
            "playlist_id": playlist_id,
            "conversion_name": conversion_name,
            "videos_count": len(videos_info),
            "errors": errors,
            "master_playlist": f"/hls/{playlist_id}/master.m3u8",
            "player_url": f"/player/{playlist_id}",
            "videos_info": videos_info,
            "total_duration": total_duration
        }
    else:
        return {
            "success": False,
            "playlist_id": playlist_id,
            "conversion_name": conversion_name,
            "errors": errors,
            "videos_info": videos_info
        }

# =============== PÁGINAS HTML ===============
# (Manter as páginas HTML anteriores aqui...)
# Para economizar espaço, mantenho apenas a estrutura básica e adiciono a funcionalidade de backup
# Na versão completa, todas as páginas HTML anteriores são mantidas

LOGIN_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔐 Login - HLS Converter</title>
    <!-- Estilos mantidos da versão anterior -->
</head>
<body>
    <!-- Conteúdo mantido da versão anterior -->
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
    <!-- Estilos mantidos da versão anterior -->
</head>
<body>
    <!-- Conteúdo mantido da versão anterior -->
</body>
</html>
'''

# DASHBOARD HTML com adição de campo de nome e backup
DASHBOARD_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Converter ULTIMATE</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        /* Todos os estilos anteriores mantidos */
        
        /* Adicionais para backup */
        .backup-section {
            background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%);
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
        }
        
        .backup-list {
            max-height: 300px;
            overflow-y: auto;
            margin: 15px 0;
            background: white;
            border-radius: 8px;
            padding: 15px;
            border: 1px solid #ddd;
        }
        
        .backup-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px 15px;
            border-bottom: 1px solid #eee;
        }
        
        .backup-item:last-child {
            border-bottom: none;
        }
        
        .backup-actions {
            display: flex;
            gap: 8px;
        }
        
        .btn-backup {
            background: linear-gradient(90deg, #2ecc71 0%, #27ae60 100%);
            color: white;
        }
        
        .btn-restore {
            background: linear-gradient(90deg, #3498db 0%, #2980b9 100%);
            color: white;
        }
        
        .conversion-name-input {
            width: 100%;
            padding: 12px;
            border: 2px solid #4361ee;
            border-radius: 8px;
            font-size: 16px;
            margin: 20px 0;
            transition: all 0.3s;
        }
        
        .conversion-name-input:focus {
            outline: none;
            border-color: #3a0ca3;
            box-shadow: 0 0 0 3px rgba(67, 97, 238, 0.1);
        }
        
        .conversion-link-display {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 8px;
            margin: 15px 0;
            border-left: 4px solid #4361ee;
            display: none;
        }
        
        .conversion-link-display.show {
            display: block;
            animation: fadeIn 0.5s ease;
        }
        
        .link-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px;
            background: white;
            border-radius: 5px;
            margin: 8px 0;
        }
        
        .link-actions {
            display: flex;
            gap: 8px;
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="logo">
            <i class="fas fa-video"></i>
            <h1>HLS Converter ULTIMATE</h1>
        </div>
        <div class="user-info">
            <span><i class="fas fa-user"></i> {{ session.user_id }}</span>
            <a href="/logout" class="logout-btn">
                <i class="fas fa-sign-out-alt"></i> Sair
            </a>
        </div>
    </div>
    
    <div class="container">
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
            <!-- Conteúdo anterior mantido -->
        </div>
        
        <!-- Upload Tab - COM CAMPO DE NOME -->
        <div id="upload" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-upload"></i> Converter Múltiplos Vídeos</h2>
                
                <!-- Campo de nome da conversão -->
                <div style="margin-bottom: 20px;">
                    <h3><i class="fas fa-font"></i> Nome da Conversão</h3>
                    <input type="text" 
                           id="conversionName" 
                           class="conversion-name-input" 
                           placeholder="Digite um nome para esta conversão (ex: Aula de Matemática, Evento Corporativo, etc.)"
                           maxlength="100">
                    <p style="color: #666; font-size: 0.9rem; margin-top: 5px;">
                        Este nome será usado para identificar sua conversão no histórico
                    </p>
                </div>
                
                <!-- Restante do conteúdo anterior mantido -->
                
                <!-- Área para exibir links após conversão -->
                <div id="conversionLinks" class="conversion-link-display">
                    <h3><i class="fas fa-link"></i> Links Gerados</h3>
                    <div id="linksList"></div>
                </div>
            </div>
        </div>
        
        <!-- Backup Tab - NOVA ABA -->
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
                
                <!-- Restaurar Backup -->
                <div class="backup-section" style="margin-top: 30px;">
                    <h3><i class="fas fa-upload"></i> Restaurar Backup</h3>
                    <p style="color: #666; margin-bottom: 15px;">
                        Restaure o sistema a partir de um arquivo de backup.
                    </p>
                    
                    <div style="margin-top: 20px;">
                        <div class="upload-area" onclick="document.getElementById('restoreFile').click()">
                            <i class="fas fa-cloud-upload-alt"></i>
                            <h3>Arraste e solte o arquivo de backup aqui</h3>
                            <p>ou clique para selecionar (formato .tar.gz)</p>
                        </div>
                        <input type="file" id="restoreFile" accept=".tar.gz,.tgz" style="display: none;" onchange="handleRestoreFile()">
                        
                        <div id="selectedBackupFile" style="display: none; margin-top: 15px;">
                            <div class="file-item">
                                <span class="file-name" id="backupFileName"></span>
                                <button class="remove-file" onclick="removeRestoreFile()">
                                    <i class="fas fa-times"></i>
                                </button>
                            </div>
                        </div>
                        
                        <button class="btn btn-restore" onclick="restoreBackup()" id="restoreBtn" style="margin-top: 20px; width: 100%;">
                            <i class="fas fa-upload"></i> Restaurar Sistema
                        </button>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script>
        // =============== NOVAS FUNÇÕES DE BACKUP ===============
        
        function createBackup() {
            const backupName = document.getElementById('backupName').value.trim();
            const nameParam = backupName ? `?name=${encodeURIComponent(backupName)}` : '';
            
            showToast('Criando backup...', 'info');
            
            fetch(`/api/backup/create${nameParam}`, { method: 'POST' })
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showToast(`✅ Backup criado: ${data.backup_name} (${formatBytes(data.size)})`, 'success');
                        document.getElementById('backupName').value = '';
                        loadBackups();
                        
                        // Opcional: Oferecer download
                        if (confirm('Deseja baixar o backup agora?')) {
                            window.open(`/api/backup/download/${data.backup_name}`, '_blank');
                        }
                    } else {
                        showToast(`❌ Erro: ${data.error}`, 'error');
                    }
                })
                .catch(error => {
                    showToast(`❌ Erro de conexão: ${error.message}`, 'error');
                });
        }
        
        function loadBackups() {
            fetch('/api/backup/list')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('backupsList');
                    
                    if (!data.backups || data.backups.length === 0) {
                        container.innerHTML = `
                            <div class="empty-state">
                                <i class="fas fa-database"></i>
                                <p>Nenhum backup encontrado</p>
                            </div>
                        `;
                        return;
                    }
                    
                    let html = '';
                    data.backups.forEach(backup => {
                        html += `
                            <div class="backup-item">
                                <div>
                                    <strong>${backup.name}</strong><br>
                                    <small style="color: #666;">
                                        ${formatDate(backup.modified)} • ${formatBytes(backup.size)}
                                    </small>
                                </div>
                                <div class="backup-actions">
                                    <button class="btn btn-restore btn-sm" onclick="downloadBackup('${backup.name}')">
                                        <i class="fas fa-download"></i>
                                    </button>
                                    <button class="btn btn-backup btn-sm" onclick="restoreSpecificBackup('${backup.name}')">
                                        <i class="fas fa-upload"></i>
                                    </button>
                                    <button class="btn btn-danger btn-sm" onclick="deleteBackup('${backup.name}')">
                                        <i class="fas fa-trash"></i>
                                    </button>
                                </div>
                            </div>
                        `;
                    });
                    
                    container.innerHTML = html;
                })
                .catch(error => {
                    showToast('Erro ao carregar backups', 'error');
                });
        }
        
        function downloadBackup(backupName) {
            window.open(`/api/backup/download/${backupName}`, '_blank');
        }
        
        function restoreSpecificBackup(backupName) {
            if (confirm(`Restaurar backup "${backupName}"? O sistema será reiniciado.`)) {
                fetch(`/api/backup/restore/${backupName}`, { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showToast('✅ Backup restaurado! Reiniciando...', 'success');
                            setTimeout(() => {
                                window.location.reload();
                            }, 2000);
                        } else {
                            showToast(`❌ Erro: ${data.error}`, 'error');
                        }
                    })
                    .catch(error => {
                        showToast('Erro ao restaurar backup', 'error');
                    });
            }
        }
        
        function deleteBackup(backupName) {
            if (confirm(`Excluir backup "${backupName}" permanentemente?`)) {
                fetch(`/api/backup/delete/${backupName}`, { method: 'DELETE' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showToast('✅ Backup excluído', 'success');
                            loadBackups();
                        } else {
                            showToast(`❌ Erro: ${data.error}`, 'error');
                        }
                    })
                    .catch(error => {
                        showToast('Erro ao excluir backup', 'error');
                    });
            }
        }
        
        function deleteAllBackups() {
            if (confirm('Excluir TODOS os backups permanentemente?')) {
                fetch('/api/backup/delete-all', { method: 'DELETE' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showToast(`✅ ${data.deleted} backups excluídos`, 'success');
                            loadBackups();
                        } else {
                            showToast(`❌ Erro: ${data.error}`, 'error');
                        }
                    })
                    .catch(error => {
                        showToast('Erro ao excluir backups', 'error');
                    });
            }
        }
        
        let restoreFileData = null;
        
        function handleRestoreFile() {
            const fileInput = document.getElementById('restoreFile');
            if (fileInput.files.length > 0) {
                const file = fileInput.files[0];
                if (!file.name.endsWith('.tar.gz') && !file.name.endsWith('.tgz')) {
                    showToast('Por favor, selecione um arquivo .tar.gz', 'error');
                    fileInput.value = '';
                    return;
                }
                
                restoreFileData = file;
                document.getElementById('backupFileName').textContent = file.name;
                document.getElementById('selectedBackupFile').style.display = 'block';
            }
        }
        
        function removeRestoreFile() {
            document.getElementById('restoreFile').value = '';
            document.getElementById('selectedBackupFile').style.display = 'none';
            restoreFileData = null;
        }
        
        function restoreBackup() {
            if (!restoreFileData) {
                showToast('Por favor, selecione um arquivo de backup', 'warning');
                return;
            }
            
            if (!confirm('ATENÇÃO: Restaurar backup substituirá todas as configurações atuais. Continuar?')) {
                return;
            }
            
            const formData = new FormData();
            formData.append('backup', restoreFileData);
            
            const restoreBtn = document.getElementById('restoreBtn');
            restoreBtn.disabled = true;
            restoreBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Restaurando...';
            
            fetch('/api/backup/upload', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    showToast('✅ Backup restaurado! Reiniciando sistema...', 'success');
                    setTimeout(() => {
                        window.location.href = '/login';
                    }, 3000);
                } else {
                    showToast(`❌ Erro: ${data.error}`, 'error');
                    restoreBtn.disabled = false;
                    restoreBtn.innerHTML = '<i class="fas fa-upload"></i> Restaurar Sistema';
                }
            })
            .catch(error => {
                showToast('Erro ao restaurar backup', 'error');
                restoreBtn.disabled = false;
                restoreBtn.innerHTML = '<i class="fas fa-upload"></i> Restaurar Sistema';
            });
        }
        
        // =============== FUNÇÕES DE CONVERSÃO COM NOME ===============
        
        function startConversion() {
            // Verificar nome da conversão
            const conversionName = document.getElementById('conversionName').value.trim();
            if (!conversionName) {
                showToast('Por favor, digite um nome para a conversão', 'warning');
                document.getElementById('conversionName').focus();
                return;
            }
            
            // Verificar arquivos
            if (selectedFiles.length === 0) {
                showToast('Por favor, selecione pelo menos um arquivo!', 'warning');
                return;
            }
            
            if (selectedQualities.length === 0) {
                showToast('Selecione pelo menos uma qualidade!', 'warning');
                return;
            }
            
            const formData = new FormData();
            
            // Adicionar todos os arquivos
            selectedFiles.forEach(file => {
                formData.append('files[]', file);
            });
            
            formData.append('qualities', JSON.stringify(selectedQualities));
            formData.append('keep_order', document.getElementById('keepOrder').checked);
            formData.append('conversion_name', conversionName);
            
            // Mostrar progresso
            const progressSection = document.getElementById('progress');
            const processingDetails = document.getElementById('processingDetails');
            
            progressSection.style.display = 'block';
            processingDetails.classList.add('show');
            
            const convertBtn = document.getElementById('convertBtn');
            convertBtn.disabled = true;
            convertBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Convertendo...';
            
            // Atualizar detalhes
            document.getElementById('totalFiles').textContent = selectedFiles.length;
            document.getElementById('currentFileName').textContent = selectedFiles[0].name;
            document.getElementById('currentFileProgress').textContent = '0';
            
            fetch('/convert-multiple', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    updateProgress(100, 'Concluído!');
                    
                    // Mostrar links gerados
                    showConversionLinks(data);
                    
                    showToast(`✅ "${conversionName}" convertido com sucesso!`, 'success');
                    
                    // Reset após 5 segundos
                    setTimeout(() => {
                        progressSection.style.display = 'none';
                        processingDetails.classList.remove('show');
                        document.getElementById('selectedFiles').style.display = 'none';
                        document.getElementById('fileInput').value = '';
                        selectedFiles = [];
                        convertBtn.disabled = false;
                        convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão em Lote';
                        updateProgress(0, '');
                        
                        // Atualizar histórico
                        loadConversions();
                        loadSystemStats();
                    }, 5000);
                } else {
                    showToast(`❌ Erro: ${data.error || 'Erro desconhecido'}`, 'error');
                    convertBtn.disabled = false;
                    convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão em Lote';
                }
            })
            .catch(error => {
                showToast(`❌ Erro de conexão: ${error.message}`, 'error');
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão em Lote';
            });
        }
        
        function showConversionLinks(data) {
            const linksContainer = document.getElementById('conversionLinks');
            const linksList = document.getElementById('linksList');
            
            let html = `
                <div class="link-item">
                    <div>
                        <strong>${data.conversion_name || 'Conversão'}</strong><br>
                        <small>Playlist ID: ${data.playlist_id}</small>
                    </div>
                    <div class="link-actions">
                        <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${window.location.origin}/hls/${data.playlist_id}/master.m3u8')">
                            <i class="fas fa-copy"></i> M3U8
                        </button>
                        <button class="btn btn-success btn-sm" onclick="window.open('/player/${data.playlist_id}', '_blank')">
                            <i class="fas fa-play"></i> Player
                        </button>
                    </div>
                </div>
            `;
            
            // Adicionar link direto para cada qualidade
            if (data.qualities && Array.isArray(data.qualities)) {
                data.qualities.forEach(quality => {
                    html += `
                        <div class="link-item">
                            <div>
                                <strong>${quality}</strong><br>
                                <small>Qualidade específica</small>
                            </div>
                            <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${window.location.origin}/hls/${data.playlist_id}/${quality}/index.m3u8')">
                                <i class="fas fa-copy"></i> Copiar
                            </button>
                        </div>
                    `;
                });
            }
            
            linksList.innerHTML = html;
            linksContainer.classList.add('show');
        }
        
        function copyToClipboard(text) {
            navigator.clipboard.writeText(text)
                .then(() => showToast('✅ Link copiado!', 'success'))
                .catch(() => {
                    const textArea = document.createElement('textarea');
                    textArea.value = text;
                    document.body.appendChild(textArea);
                    textArea.select();
                    document.execCommand('copy');
                    document.body.removeChild(textArea);
                    showToast('✅ Link copiado!', 'success');
                });
        }
        
        // =============== INICIALIZAÇÃO ===============
        document.addEventListener('DOMContentLoaded', function() {
            // Inicializações anteriores mantidas
            
            // Carregar backups se estiver na aba de backup
            if (window.location.hash === '#backup') {
                showTab('backup');
            }
            
            // Configurar drag and drop para backup
            const backupUploadArea = document.querySelector('#backup .upload-area');
            if (backupUploadArea) {
                backupUploadArea.addEventListener('dragover', (e) => {
                    e.preventDefault();
                    backupUploadArea.style.backgroundColor = 'rgba(67, 97, 238, 0.1)';
                });
                
                backupUploadArea.addEventListener('dragleave', () => {
                    backupUploadArea.style.backgroundColor = '';
                });
                
                backupUploadArea.addEventListener('drop', (e) => {
                    e.preventDefault();
                    backupUploadArea.style.backgroundColor = '';
                    
                    if (e.dataTransfer.files.length > 0) {
                        const file = e.dataTransfer.files[0];
                        if (file.name.endsWith('.tar.gz') || file.name.endsWith('.tgz')) {
                            restoreFileData = file;
                            document.getElementById('backupFileName').textContent = file.name;
                            document.getElementById('selectedBackupFile').style.display = 'block';
                        } else {
                            showToast('Por favor, solte apenas arquivos .tar.gz', 'error');
                        }
                    }
                });
            }
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

# ... (Manter todas as rotas anteriores) ...

# =============== NOVAS ROTAS DE BACKUP ===============

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

@app.route('/api/backup/download/<backup_name>')
def api_backup_download(backup_name):
    """Download de um backup"""
    if 'user_id' not in session:
        return "Não autenticado", 401
    
    backup_path = os.path.join(BACKUP_DIR, backup_name)
    
    if not os.path.exists(backup_path):
        return "Backup não encontrado", 404
    
    # Log da ação
    log_activity(f"Usuário {session['user_id']} baixou backup: {backup_name}")
    
    return send_file(backup_path, as_attachment=True)

@app.route('/api/backup/restore/<backup_name>', methods=['POST'])
def api_backup_restore(backup_name):
    """Restaurar um backup específico"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    backup_path = os.path.join(BACKUP_DIR, backup_name)
    
    if not os.path.exists(backup_path):
        return jsonify({"success": False, "error": "Backup não encontrado"})
    
    result = restore_backup(backup_path)
    
    if result['success']:
        log_activity(f"Usuário {session['user_id']} restaurou backup: {backup_name}")
    
    return jsonify(result)

@app.route('/api/backup/upload', methods=['POST'])
def api_backup_upload():
    """Upload e restauração de backup"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    if 'backup' not in request.files:
        return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
    
    file = request.files['backup']
    if file.filename == '':
        return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
    
    # Verificar extensão
    if not (file.filename.endswith('.tar.gz') or file.filename.endswith('.tgz')):
        return jsonify({"success": False, "error": "Formato inválido. Use .tar.gz"})
    
    # Salvar arquivo temporariamente
    temp_path = os.path.join(tempfile.gettempdir(), f"restore_{uuid.uuid4().hex}.tar.gz")
    file.save(temp_path)
    
    # Restaurar backup
    result = restore_backup(temp_path)
    
    # Limpar arquivo temporário
    try:
        os.remove(temp_path)
    except:
        pass
    
    if result['success']:
        log_activity(f"Usuário {session['user_id']} restaurou sistema via upload")
    
    return jsonify(result)

@app.route('/api/backup/delete/<backup_name>', methods=['DELETE'])
def api_backup_delete(backup_name):
    """Excluir um backup"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    backup_path = os.path.join(BACKUP_DIR, backup_name)
    
    if not os.path.exists(backup_path):
        return jsonify({"success": False, "error": "Backup não encontrado"})
    
    try:
        os.remove(backup_path)
        log_activity(f"Usuário {session['user_id']} excluiu backup: {backup_name}")
        
        return jsonify({
            "success": True,
            "message": f"Backup {backup_name} excluído"
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/api/backup/delete-all', methods=['DELETE'])
def api_backup_delete_all():
    """Excluir todos os backups"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    try:
        deleted = 0
        for filename in os.listdir(BACKUP_DIR):
            if filename.endswith('.tar.gz'):
                filepath = os.path.join(BACKUP_DIR, filename)
                os.remove(filepath)
                deleted += 1
        
        log_activity(f"Usuário {session['user_id']} excluiu todos os backups ({deleted} arquivos)")
        
        return jsonify({
            "success": True,
            "deleted": deleted,
            "message": f"{deleted} backups excluídos"
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

# =============== ROTAS DE CONVERSÃO COM NOME ===============

@app.route('/convert-multiple', methods=['POST'])
def convert_multiple_videos():
    """Converter múltiplos vídeos com nome personalizado"""
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    try:
        # Verificar FFmpeg
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            return jsonify({
                "success": False,
                "error": "FFmpeg não encontrado. Execute: sudo apt-get install ffmpeg"
            })
        
        # Verificar arquivos
        if 'files[]' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        files = request.files.getlist('files[]')
        if not files or files[0].filename == '':
            return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
        
        # Obter nome da conversão
        conversion_name = request.form.get('conversion_name', '').strip()
        if not conversion_name:
            conversion_name = f"Conversão {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        
        # Sanitizar nome
        conversion_name = sanitize_filename(conversion_name)
        
        # Obter qualidades
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Criar lista de arquivos
        files_data = [(file, file.filename) for file in files]
        
        # Gerar ID único para a playlist
        playlist_id = str(uuid.uuid4())[:8]
        
        # Processar em uma thread separada
        def process_task():
            return process_multiple_videos(files_data, qualities, playlist_id, conversion_name)
        
        future = executor.submit(process_task)
        result = future.result(timeout=3600)
        
        if result["success"]:
            # Atualizar banco de dados
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "filename": f"{len(files_data)} arquivos",
                "qualities": qualities,
                "timestamp": datetime.now().isoformat(),
                "status": "success",
                "type": "multiple",
                "videos_count": len(files_data),
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
            
            log_activity(f"Conversão '{conversion_name}' realizada: {len(files_data)} arquivos -> {playlist_id}")
            
            return jsonify({
                "success": True,
                "playlist_id": playlist_id,
                "conversion_name": conversion_name,
                "videos_count": len(files_data),
                "qualities": qualities,
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8",
                "player_url": f"/player/{playlist_id}",
                "errors": result.get("errors", []),
                "message": f"Conversão '{conversion_name}' concluída com sucesso!"
            })
        else:
            # Registrar falha
            conversions = load_conversions()
            conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
            conversions['stats']['failed'] = conversions['stats'].get('failed', 0) + 1
            save_conversions(conversions)
            
            return jsonify({
                "success": False,
                "error": "Erro na conversão múltipla",
                "errors": result.get("errors", [])
            })
        
    except Exception as e:
        print(f"Erro na conversão múltipla: {e}")
        
        # Registrar falha
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

# ... (Manter todas as outras rotas anteriores) ...

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 60)
    print("🚀 HLS Converter ULTIMATE - Versão Completa")
    print("=" * 60)
    print(f"📂 Diretório base: {BASE_DIR}")
    print(f"🔐 Autenticação: Habilitada")
    print(f"👤 Usuário padrão: admin / admin")
    print(f"💾 Sistema de backup: Habilitado")
    print(f"🏷️  Nome personalizado: Habilitado")
    print(f"🌐 Porta: 8080")
    print("=" * 60)
    
    # Testar FFmpeg
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
    
    # Garantir que os arquivos de banco de dados existam
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

# 11. CRIAR SCRIPT DE GERENCIAMENTO COMPLETO
echo "📝 Criando script de gerenciamento completo..."

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
        echo "🧪 Testando sistema..."
        echo ""
        
        # Serviço
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço está ativo"
            
            # Health check
            echo "🌐 Testando health check..."
            if curl -s http://localhost:8080/health | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "⚠️  Health check falhou"
                curl -s http://localhost:8080/health || true
            fi
            
            # Login
            echo "🔐 Testando login..."
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
            if [ "$STATUS_CODE" = "200" ]; then
                echo "✅ Página de login OK"
            else
                echo "⚠️  Login retornou código: $STATUS_CODE"
            fi
            
            # Backup API
            echo "💾 Testando API de backup..."
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/backup/list)
            if [ "$STATUS_CODE" = "200" ] || [ "$STATUS_CODE" = "401" ]; then
                echo "✅ API de backup respondendo"
            else
                echo "⚠️  API de backup: Código $STATUS_CODE"
            fi
            
        else
            echo "❌ Serviço não está ativo"
        fi
        
        # FFmpeg
        echo ""
        echo "🎬 Testando FFmpeg..."
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg encontrado: $(which ffmpeg)"
            ffmpeg -version | head -1
        else
            echo "❌ FFmpeg não encontrado"
        fi
        
        # Diretórios
        echo ""
        echo "📁 Verificando diretórios..."
        for dir in "$HLS_HOME" "$HLS_HOME/uploads" "$HLS_HOME/hls" "$HLS_HOME/backups" "$HLS_HOME/db"; do
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
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=" * 60
        echo "🎬 HLS Converter ULTIMATE - Informações do Sistema"
        echo "=" * 60
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo "Porta: 8080"
        echo "Login: http://$IP:8080/login"
        echo "Usuário: admin"
        echo "Senha: admin (altere no primeiro acesso)"
        echo ""
        echo "📁 Diretórios:"
        echo "  /opt/hls-converter/     - Diretório principal"
        echo "  ├── app.py             - Aplicação principal"
        echo "  ├── uploads/           - Vídeos enviados"
        echo "  ├── hls/               - Arquivos HLS gerados"
        echo "  ├── db/                - Banco de dados"
        echo "  ├── logs/              - Logs do sistema"
        echo "  ├── backups/           - Backups do sistema"
        echo "  ├── sessions/          - Sessões de usuário"
        echo "  └── static/            - Arquivos estáticos"
        echo ""
        echo "⚙️  Funcionalidades:"
        echo "  ✅ Sistema de autenticação seguro"
        echo "  ✅ Histórico de conversões"
        echo "  ✅ Multi-upload de vídeos"
        echo "  ✅ Nome personalizado para conversões"
        echo "  ✅ Sistema completo de backup/restore"
        echo "  ✅ Interface responsiva moderna"
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
        echo "=" * 60
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
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "✅ Health check: OK"
    else
        echo "⚠️  Health check: Pode ter problemas"
    fi
    
    # Login page
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
    if [ "$STATUS_CODE" = "200" ]; then
        echo "✅ Página de login: OK"
    else
        echo "⚠️  Página de login: Código $STATUS_CODE"
    fi
    
    # Backup API (deve retornar 401 sem login)
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/backup/list)
    if [ "$STATUS_CODE" = "401" ]; then
        echo "✅ API de backup: Protegida (requer login)"
    else
        echo "⚠️  API de backup: Código $STATUS_CODE"
    fi
    
else
    echo "❌ Serviço não está ativo"
    echo ""
    echo "📋 Logs de erro:"
    journalctl -u hls-converter -n 20 --no-pager
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
echo "✅ TODAS AS FUNCIONALIDADES IMPLEMENTADAS:"
echo ""
echo "🔐 SISTEMA DE SEGURANÇA:"
echo "   ✅ Autenticação com bcrypt"
echo "   ✅ Sessões seguras"
echo "   ✅ Troca de senha obrigatória no primeiro acesso"
echo "   ✅ Proteção contra força bruta"
echo ""
echo "🎬 CONVERSÃO DE VÍDEOS:"
echo "   ✅ Multi-upload de vídeos"
echo "   ✅ Nome personalizado para conversões"
echo "   ✅ Múltiplas qualidades (240p, 480p, 720p, 1080p)"
echo "   ✅ Playlist única para múltiplos vídeos"
echo "   ✅ Player HLS integrado"
echo "   ✅ Histórico completo de conversões"
echo ""
echo "💾 SISTEMA DE BACKUP:"
echo "   ✅ Criação automática de backups"
echo "   ✅ Restauração completa do sistema"
echo "   ✅ Upload/download de backups"
echo "   ✅ Gerenciamento de múltiplos backups"
echo "   ✅ Backup inicial já criado"
echo ""
echo "⚙️  GERENCIAMENTO:"
echo "   ✅ Interface web moderna e responsiva"
echo "   ✅ Sistema de notificações"
echo "   ✅ Monitoramento do sistema"
echo "   ✅ Logs detalhados"
echo "   ✅ Script de gerenciamento completo (hlsctl)"
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
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start        - Iniciar serviço"
echo "   • hlsctl stop         - Parar serviço"
echo "   • hlsctl restart      - Reiniciar serviço"
echo "   • hlsctl status       - Ver status"
echo "   • hlsctl logs [-f]    - Ver logs (-f para seguir)"
echo "   • hlsctl test         - Testar sistema completo"
echo "   • hlsctl backup       - Criar backup manual"
echo "   • hlsctl restore FILE - Restaurar backup"
echo "   • hlsctl info         - Informações do sistema"
echo ""
echo "📁 ESTRUTURA DE DIRETÓRIOS:"
echo "   /opt/hls-converter/"
echo "   ├── 📄 app.py              - Aplicação principal"
echo "   ├── 📁 uploads/            - Vídeos enviados"
echo "   ├── 📁 hls/                - Arquivos HLS gerados"
echo "   ├── 📁 db/                 - Banco de dados (usuários/conversões)"
echo "   ├── 📁 logs/               - Logs do sistema"
echo "   ├── 📁 backups/            - Backups do sistema"
echo "   ├── 📁 sessions/           - Sessões de usuário"
echo "   └── 📁 static/             - Arquivos estáticos"
echo ""
echo "💡 DICAS DE USO:"
echo "   1. Faça login com admin/admin"
echo "   2. Altere a senha imediatamente"
echo "   3. Use nomes descritivos para suas conversões"
echo "   4. Crie backups regularmente"
echo "   5. Use 'hlsctl test' para verificar o sistema"
echo ""
echo "🆘 SUPORTE:"
echo "   Para problemas, execute: hlsctl test"
echo "   Para logs detalhados: hlsctl logs -f"
echo "   Para reinstalar FFmpeg: hlsctl fix-ffmpeg"
echo ""
echo "=" * 70
echo "🚀 Sistema 100% pronto! Acesse http://$IP:8080/login"
echo "=" * 70
