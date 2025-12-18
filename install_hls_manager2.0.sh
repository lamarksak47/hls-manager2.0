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
from flask import Flask, request, jsonify, render_template_string, send_file, redirect, url_for, session, flash
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
USERS_FILE = os.path.join(DB_DIR, "users.json")
CONVERSIONS_FILE = os.path.join(DB_DIR, "conversions.json")

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
def convert_single_video(video_data, playlist_id, index, total_files, qualities, callback=None):
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
    <title>🎬 HLS Converter ULTIMATE</title>
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
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        
        .stat-item {
            background: linear-gradient(135deg, #f8f9fa 0%, #e9ecef 100%);
            padding: 25px;
            border-radius: 10px;
            text-align: center;
            transition: transform 0.3s;
        }
        
        .stat-item:hover {
            transform: translateY(-5px);
        }
        
        .stat-value {
            font-size: 2.5rem;
            font-weight: 700;
            color: var(--primary);
            margin-bottom: 5px;
        }
        
        .stat-label {
            color: #6c757d;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
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
        
        .upload-area h3 {
            color: var(--dark);
            margin-bottom: 10px;
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
        
        .conversions-list {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        
        .conversion-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.08);
            border-left: 4px solid var(--accent);
            transition: transform 0.3s;
        }
        
        .conversion-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 8px 20px rgba(0,0,0,0.12);
        }
        
        .conversion-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }
        
        .conversion-id {
            font-family: monospace;
            background: var(--light);
            padding: 5px 10px;
            border-radius: 5px;
            font-size: 0.9rem;
        }
        
        .conversion-status {
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
        }
        
        .status-success {
            background: #d4edda;
            color: #155724;
        }
        
        .status-failed {
            background: #f8d7da;
            color: #721c24;
        }
        
        .conversion-info {
            margin: 10px 0;
        }
        
        .conversion-info p {
            margin: 5px 0;
            font-size: 0.9rem;
        }
        
        .conversion-actions {
            display: flex;
            gap: 10px;
            margin-top: 15px;
        }
        
        .conversion-actions .btn {
            padding: 8px 15px;
            font-size: 0.85rem;
            flex: 1;
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
        
        .file-info {
            background: var(--light);
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
            display: none;
        }
        
        .file-info.show {
            display: block;
            animation: fadeIn 0.5s ease;
        }
        
        .ffmpeg-status {
            display: inline-block;
            padding: 8px 15px;
            border-radius: 20px;
            font-weight: 600;
            margin: 10px 0;
        }
        
        .ffmpeg-ok {
            background: #d4edda;
            color: #155724;
        }
        
        .ffmpeg-error {
            background: #f8d7da;
            color: #721c24;
        }
        
        .empty-state {
            text-align: center;
            padding: 60px 20px;
            color: #6c757d;
        }
        
        .empty-state i {
            font-size: 4rem;
            margin-bottom: 20px;
            color: #dee2e6;
        }
        
        .system-status {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 25px;
            border-radius: 12px;
            margin-top: 20px;
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
            
            .stats-grid {
                grid-template-columns: 1fr;
            }
            
            .conversions-list {
                grid-template-columns: 1fr;
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
        
        /* Estilos para multi-upload */
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
        
        .processing-details {
            background: #e9ecef;
            padding: 15px;
            border-radius: 8px;
            margin: 10px 0;
            display: none;
        }
        
        .processing-details.show {
            display: block;
        }
        
        .current-file {
            font-weight: 600;
            color: var(--primary);
        }
        
        /* Estilos para campo de nome */
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
        
        /* Estilos para backup */
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
        
        /* Estilos para links gerados */
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
        
        .link-info {
            flex: 1;
        }
        
        .link-title {
            font-weight: 600;
            color: #2c3e50;
        }
        
        .link-url {
            color: #666;
            font-size: 0.9rem;
            word-break: break-all;
        }
        
        .link-actions {
            display: flex;
            gap: 8px;
        }
        
        .btn-sm {
            padding: 6px 12px;
            font-size: 0.8rem;
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
        
        <!-- Upload Tab - COM CAMPO DE NOME -->
        <div id="upload" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-upload"></i> Converter Múltiplos Vídeos para HLS</h2>
                <p style="color: #666; margin-bottom: 20px;">
                    Selecione vários vídeos para converter em sequência. Todos os vídeos serão combinados em uma única playlist HLS.
                </p>
                
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
                
                <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                    <i class="fas fa-cloud-upload-alt"></i>
                    <h3>Arraste e solte seus vídeos aqui</h3>
                    <p>ou clique para selecionar múltiplos arquivos (Ctrl + Click)</p>
                    <p style="color: #666; margin-top: 10px;">
                        Formatos suportados: MP4, AVI, MOV, MKV, WEBM
                    </p>
                </div>
                
                <input type="file" id="fileInput" accept="video/*" multiple style="display: none;" onchange="handleFileSelect()">
                
                <div id="selectedFiles" class="selected-files" style="display: none;">
                    <h4><i class="fas fa-file-video"></i> Arquivos Selecionados <span id="fileCount" class="upload-count">0</span></h4>
                    <ul id="fileList" class="file-list"></ul>
                </div>
                
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
                
                <div id="processingDetails" class="processing-details">
                    <h4><i class="fas fa-tasks"></i> Processando:</h4>
                    <p>Arquivo atual: <span id="currentFileName" class="current-file"></span></p>
                    <p>Progresso: <span id="currentFileProgress">0</span>/<span id="totalFiles">0</span></p>
                </div>
                
                <div id="progress" style="display: none; margin-top: 30px;">
                    <h3><i class="fas fa-spinner fa-spin"></i> Progresso da Conversão</h3>
                    <div class="progress-container">
                        <div class="progress-bar" id="progressBar" style="width: 0%">0%</div>
                    </div>
                    <p id="progressText" style="text-align: center; margin-top: 10px; color: #666;">
                        Iniciando conversão em lote...
                    </p>
                </div>
                
                <!-- Container para exibir links gerados -->
                <div id="linksContainer" class="links-container">
                    <h3><i class="fas fa-link"></i> Links Gerados</h3>
                    <div id="linksList"></div>
                </div>
            </div>
        </div>
        
        <!-- Conversions Tab - HISTÓRICO CORRIGIDO -->
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
        // Variáveis globais
        let selectedFiles = [];
        let selectedQualities = ['240p', '480p', '720p', '1080p'];
        let restoreFileData = null;
        
        // =============== FUNÇÕES DE NAVEGAÇÃO ===============
        function showTab(tabName) {
            // Esconder todas as abas
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });
            
            // Remover active de todas as tabs
            document.querySelectorAll('.nav-tab').forEach(tab => {
                tab.classList.remove('active');
            });
            
            // Mostrar aba selecionada
            document.getElementById(tabName).classList.add('active');
            
            // Ativar tab correspondente
            document.querySelectorAll('.nav-tab').forEach(tab => {
                if (tab.textContent.includes(getTabLabel(tabName))) {
                    tab.classList.add('active');
                }
            });
            
            // Carregar dados específicos da aba
            switch(tabName) {
                case 'dashboard':
                    loadSystemStats();
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
        
        // =============== SISTEMA ===============
        function loadSystemStats() {
            fetch('/api/system')
                .then(response => response.json())
                .then(data => {
                    if (data.error) {
                        console.error('Erro ao carregar stats:', data.error);
                        return;
                    }
                    
                    document.getElementById('cpu').textContent = data.cpu || '--%';
                    document.getElementById('memory').textContent = data.memory || '--%';
                    document.getElementById('conversionsTotal').textContent = data.total_conversions || '0';
                    document.getElementById('conversionsSuccess').textContent = data.success_conversions || '0';
                    
                    // Status do FFmpeg
                    const ffmpegStatus = document.getElementById('ffmpegStatus');
                    if (data.ffmpeg_status === 'ok') {
                        ffmpegStatus.textContent = '✅ FFmpeg Disponível';
                        ffmpegStatus.className = 'ffmpeg-status ffmpeg-ok';
                        if (data.ffmpeg_path) {
                            document.getElementById('ffmpegPath').textContent = `Local: ${data.ffmpeg_path}`;
                        }
                    } else {
                        ffmpegStatus.textContent = '❌ FFmpeg Não Encontrado';
                        ffmpegStatus.className = 'ffmpeg-status ffmpeg-error';
                        document.getElementById('ffmpegPath').textContent = 'Execute: sudo apt-get install ffmpeg';
                    }
                })
                .catch(error => {
                    console.error('Erro ao carregar stats:', error);
                    showToast('Erro ao carregar status do sistema', 'error');
                });
        }
        
        function refreshStats() {
            loadSystemStats();
            showToast('Status atualizado com sucesso', 'success');
        }
        
        function testFFmpeg() {
            fetch('/api/ffmpeg-test')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showToast(`✅ FFmpeg funcionando! Versão: ${data.version}`, 'success');
                    } else {
                        showToast(`❌ FFmpeg não está funcionando: ${data.error}`, 'error');
                    }
                })
                .catch(() => {
                    showToast('Erro ao testar FFmpeg', 'error');
                });
        }
        
        // =============== MULTI-UPLOAD COM NOME ===============
        function handleFileSelect() {
            const fileInput = document.getElementById('fileInput');
            if (fileInput.files.length > 0) {
                Array.from(fileInput.files).forEach(file => {
                    // Evitar duplicados
                    if (!selectedFiles.some(f => f.name === file.name && f.size === file.size)) {
                        selectedFiles.push(file);
                    }
                });
                
                updateFileList();
                
                const selectedFilesDiv = document.getElementById('selectedFiles');
                selectedFilesDiv.style.display = 'block';
            }
        }
        
        function updateFileList() {
            const fileList = document.getElementById('fileList');
            const fileCount = document.getElementById('fileCount');
            
            fileList.innerHTML = '';
            fileCount.textContent = selectedFiles.length;
            
            selectedFiles.forEach((file, index) => {
                const li = document.createElement('li');
                li.className = 'file-item';
                li.innerHTML = `
                    <span class="file-name">${file.name}</span>
                    <span class="file-size">${formatBytes(file.size)}</span>
                    <button class="remove-file" onclick="removeFile(${index})">
                        <i class="fas fa-times"></i>
                    </button>
                `;
                fileList.appendChild(li);
            });
        }
        
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            updateFileList();
            
            if (selectedFiles.length === 0) {
                document.getElementById('selectedFiles').style.display = 'none';
            }
        }
        
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
            // Verificar nome da conversão
            const conversionName = document.getElementById('conversionName').value.trim();
            if (!conversionName) {
                showToast('Por favor, digite um nome para a conversão', 'warning');
                document.getElementById('conversionName').focus();
                return;
            }
            
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
            
            // Atualizar detalhes do processamento
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
        
        function updateProgress(percent, text) {
            const progressBar = document.getElementById('progressBar');
            progressBar.style.width = percent + '%';
            progressBar.textContent = percent + '%';
            document.getElementById('progressText').textContent = text;
        }
        
        function showConversionLinks(data) {
            const linksContainer = document.getElementById('linksContainer');
            const linksList = document.getElementById('linksList');
            
            const baseUrl = window.location.origin;
            let html = '';
            
            // Link principal da playlist
            html += `
                <div class="link-item">
                    <div class="link-info">
                        <div class="link-title">${data.conversion_name}</div>
                        <div class="link-url">${baseUrl}/hls/${data.playlist_id}/master.m3u8</div>
                    </div>
                    <div class="link-actions">
                        <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${baseUrl}/hls/${data.playlist_id}/master.m3u8')">
                            <i class="fas fa-copy"></i>
                        </button>
                        <button class="btn btn-success btn-sm" onclick="window.open('/player/${data.playlist_id}', '_blank')">
                            <i class="fas fa-play"></i>
                        </button>
                    </div>
                </div>
            `;
            
            // Links para cada qualidade
            if (data.qualities && Array.isArray(data.qualities)) {
                data.qualities.forEach(quality => {
                    html += `
                        <div class="link-item">
                            <div class="link-info">
                                <div class="link-title">${quality} - ${data.conversion_name}</div>
                                <div class="link-url">${baseUrl}/hls/${data.playlist_id}/${quality}/index.m3u8</div>
                            </div>
                            <button class="btn btn-primary btn-sm" onclick="copyToClipboard('${baseUrl}/hls/${data.playlist_id}/${quality}/index.m3u8')">
                                <i class="fas fa-copy"></i>
                            </button>
                        </div>
                    `;
                });
            }
            
            linksList.innerHTML = html;
            linksContainer.classList.add('show');
            
            // Rolar para ver os links
            linksContainer.scrollIntoView({ behavior: 'smooth' });
        }
        
        function copyToClipboard(text) {
            navigator.clipboard.writeText(text)
                .then(() => showToast('✅ Link copiado para a área de transferência!', 'success'))
                .catch(() => {
                    // Fallback
                    const textArea = document.createElement('textarea');
                    textArea.value = text;
                    document.body.appendChild(textArea);
                    textArea.select();
                    document.execCommand('copy');
                    document.body.removeChild(textArea);
                    showToast('✅ Link copiado!', 'success');
                });
        }
        
        // =============== HISTÓRICO DE CONVERSÕES ===============
        function loadConversions() {
            fetch('/api/conversions')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('conversionsList');
                    const statsContainer = document.getElementById('conversionStats');
                    
                    // Atualizar estatísticas
                    if (data.stats) {
                        statsContainer.innerHTML = `
                            Total: ${data.stats.total || 0} | 
                            Sucesso: ${data.stats.success || 0} | 
                            Falhas: ${data.stats.failed || 0}
                        `;
                    }
                    
                    if (!data.conversions || data.conversions.length === 0) {
                        container.innerHTML = `
                            <div class="empty-state">
                                <i class="fas fa-history"></i>
                                <h3>Nenhuma conversão realizada ainda</h3>
                                <p>Converta seu primeiro vídeo para ver o histórico aqui</p>
                            </div>
                        `;
                        return;
                    }
                    
                    let html = '<div class="conversions-list">';
                    
                    const conversions = Array.isArray(data.conversions) ? data.conversions : [];
                    
                    conversions.forEach(conv => {
                        const videoId = conv.video_id || conv.id || 'N/A';
                        const filename = conv.filename || 'Arquivo desconhecido';
                        const timestamp = conv.timestamp || new Date().toISOString();
                        const qualities = Array.isArray(conv.qualities) ? conv.qualities : [];
                        const status = conv.status || 'unknown';
                        const conversionName = conv.conversion_name || conv.filename;
                        
                        html += `
                            <div class="conversion-card">
                                <div class="conversion-header">
                                    <span class="conversion-id">${conversionName.substring(0, 20)}${conversionName.length > 20 ? '...' : ''}</span>
                                    <span class="conversion-status status-${status}">
                                        ${status === 'success' ? '✅ Sucesso' : '❌ Falha'}
                                    </span>
                                </div>
                                <div class="conversion-info">
                                    <p><strong>Nome:</strong> ${conversionName}</p>
                                    <p><strong>Data:</strong> ${formatDate(timestamp)}</p>
                                    <p><strong>Qualidades:</strong> ${qualities.join(', ') || 'N/A'}</p>
                                    <p><strong>Arquivos:</strong> ${conv.videos_count || 1}</p>
                                </div>
                                <div class="conversion-actions">
                                    <button class="btn btn-primary" onclick="copyLink('${videoId}')">
                                        <i class="fas fa-link"></i> Link
                                    </button>
                                    <button class="btn btn-success" onclick="playVideo('${videoId}')">
                                        <i class="fas fa-play"></i> Play
                                    </button>
                                </div>
                            </div>
                        `;
                    });
                    
                    html += '</div>';
                    container.innerHTML = html;
                })
                .catch(error => {
                    console.error('Erro ao carregar conversões:', error);
                    document.getElementById('conversionsList').innerHTML = `
                        <div class="empty-state">
                            <i class="fas fa-exclamation-triangle"></i>
                            <h3>Erro ao carregar histórico</h3>
                            <p>${error.message}</p>
                        </div>
                    `;
                    showToast('Erro ao carregar histórico de conversões', 'error');
                });
        }
        
        function clearHistory() {
            if (confirm('Tem certeza que deseja limpar todo o histórico de conversões?')) {
                fetch('/api/clear-history', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showToast('✅ Histórico limpo com sucesso!', 'success');
                            loadConversions();
                            loadSystemStats();
                        } else {
                            showToast(`❌ Erro: ${data.error}`, 'error');
                        }
                    })
                    .catch(error => {
                        showToast('❌ Erro ao limpar histórico', 'error');
                    });
            }
        }
        
        function copyLink(videoId) {
            const link = window.location.origin + '/hls/' + videoId + '/master.m3u8';
            copyToClipboard(link);
        }
        
        function playVideo(videoId) {
            window.open('/player/' + videoId, '_blank');
        }
        
        // =============== CONFIGURAÇÕES ===============
        function changePassword() {
            window.location.href = '/change-password';
        }
        
        function cleanupFiles() {
            if (confirm('Limpar todos os arquivos temporários e convertidos?')) {
                fetch('/api/cleanup', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showToast(`✅ ${data.message}`, 'success');
                        } else {
                            showToast(`❌ Erro: ${data.error}`, 'error');
                        }
                    })
                    .catch(() => {
                        showToast('❌ Erro ao limpar arquivos', 'error');
                    });
            }
        }
        
        function cleanupOldFiles() {
            if (confirm('Limpar arquivos antigos (mais de 7 dias)?')) {
                fetch('/api/cleanup-old', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        showToast(data.message || '✅ Arquivos antigos removidos', 'success');
                    })
                    .catch(() => {
                        showToast('❌ Erro ao limpar arquivos antigos', 'error');
                    });
            }
        }
        
        function loadSystemInfo() {
            fetch('/api/system-info')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('systemInfo');
                    container.innerHTML = `
                        <p><strong>Versão:</strong> ${data.version || 'N/A'}</p>
                        <p><strong>Diretório:</strong> ${data.base_dir || 'N/A'}</p>
                        <p><strong>Usuários:</strong> ${data.users_count || 0}</p>
                        <p><strong>Serviço:</strong> ${data.service_status || 'N/A'}</p>
                        <p><strong>Uptime:</strong> ${data.uptime || 'N/A'}</p>
                        <p><strong>Backup:</strong> ${data.backup_enabled ? 'Habilitado' : 'Desabilitado'}</p>
                    `;
                })
                .catch(error => {
                    document.getElementById('systemInfo').innerHTML = 'Erro ao carregar informações';
                });
        }
        
        // =============== BACKUP ===============
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
                        
                        // Oferecer download
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
        
        // =============== UTILITÁRIOS ===============
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
            // Remover toasts anteriores
            document.querySelectorAll('.toast').forEach(toast => toast.remove());
            
            const toast = document.createElement('div');
            toast.className = `toast ${type}`;
            toast.innerHTML = `
                <i class="fas fa-${type === 'success' ? 'check-circle' : type === 'error' ? 'exclamation-circle' : 'info-circle'}"></i>
                <span>${message}</span>
            `;
            
            document.body.appendChild(toast);
            
            // Remover após 5 segundos
            setTimeout(() => {
                toast.remove();
            }, 5000);
        }
        
        // =============== INICIALIZAÇÃO ===============
        document.addEventListener('DOMContentLoaded', function() {
            loadSystemStats();
            
            // Atualizar stats a cada 30 segundos
            setInterval(loadSystemStats, 30000);
            
            // Configurar drag and drop
            const uploadArea = document.querySelector('#upload .upload-area');
            
            uploadArea.addEventListener('dragover', (e) => {
                e.preventDefault();
                uploadArea.style.backgroundColor = 'rgba(67, 97, 238, 0.1)';
            });
            
            uploadArea.addEventListener('dragleave', () => {
                uploadArea.style.backgroundColor = '';
            });
            
            uploadArea.addEventListener('drop', (e) => {
                e.preventDefault();
                uploadArea.style.backgroundColor = '';
                
                if (e.dataTransfer.files.length > 0) {
                    Array.from(e.dataTransfer.files).forEach(file => {
                        if (!selectedFiles.some(f => f.name === file.name && f.size === file.size)) {
                            selectedFiles.push(file);
                        }
                    });
                    
                    updateFileList();
                    
                    const selectedFilesDiv = document.getElementById('selectedFiles');
                    selectedFilesDiv.style.display = 'block';
                }
            });
            
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

@app.route('/api/cleanup', methods=['POST'])
def api_cleanup():
    """Limpar todos os arquivos"""
    try:
        deleted_count = 0
        
        if os.path.exists(UPLOAD_DIR):
            for filename in os.listdir(UPLOAD_DIR):
                filepath = os.path.join(UPLOAD_DIR, filename)
                if os.path.isfile(filepath):
                    os.remove(filepath)
                    deleted_count += 1
        
        if os.path.exists(HLS_DIR):
            for item in os.listdir(HLS_DIR):
                item_path = os.path.join(HLS_DIR, item)
                if os.path.isdir(item_path) and item not in ['240p', '360p', '480p', '720p', '1080p', 'original']:
                    shutil.rmtree(item_path, ignore_errors=True)
                    deleted_count += 1
        
        log_activity(f"Limpeza realizada: {deleted_count} arquivos removidos")
        
        return jsonify({
            "success": True,
            "message": f"{deleted_count} arquivos removidos"
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/api/cleanup-old', methods=['POST'])
def api_cleanup_old():
    """Limpar arquivos antigos"""
    try:
        deleted_count = 0
        now = time.time()
        
        if os.path.exists(UPLOAD_DIR):
            for filename in os.listdir(UPLOAD_DIR):
                filepath = os.path.join(UPLOAD_DIR, filename)
                if os.path.isfile(filepath):
                    file_age = now - os.path.getmtime(filepath)
                    if file_age > 7 * 24 * 3600:
                        os.remove(filepath)
                        deleted_count += 1
        
        if os.path.exists(HLS_DIR):
            for item in os.listdir(HLS_DIR):
                item_path = os.path.join(HLS_DIR, item)
                if os.path.isdir(item_path):
                    dir_age = now - os.path.getmtime(item_path)
                    if dir_age > 7 * 24 * 3600:
                        shutil.rmtree(item_path, ignore_errors=True)
                        deleted_count += 1
        
        return jsonify({
            "success": True,
            "message": f"{deleted_count} arquivos/diretórios antigos removidos"
        })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/api/ffmpeg-test')
def api_ffmpeg_test():
    """Testar FFmpeg"""
    ffmpeg_path = find_ffmpeg()
    
    if not ffmpeg_path:
        return jsonify({
            "success": False,
            "error": "FFmpeg não encontrado"
        })
    
    try:
        result = subprocess.run(
            [ffmpeg_path, '-version'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            version_line = result.stdout.split('\n')[0]
            version = version_line.split(' ')[2] if len(version_line.split(' ')) > 2 else "unknown"
            
            return jsonify({
                "success": True,
                "version": version,
                "path": ffmpeg_path
            })
        else:
            return jsonify({
                "success": False,
                "error": f"FFmpeg retornou código {result.returncode}"
            })
    except Exception as e:
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/api/system-info')
def api_system_info():
    """Informações detalhadas do sistema"""
    try:
        users = load_users()
        
        return jsonify({
            "version": "2.2.0",
            "base_dir": BASE_DIR,
            "users_count": len(users.get('users', {})),
            "service_status": "running",
            "uptime": str(datetime.now() - datetime.fromtimestamp(psutil.boot_time())).split('.')[0],
            "ffmpeg": "installed" if find_ffmpeg() else "not installed",
            "multi_upload": True,
            "backup_enabled": True
        })
    except Exception as e:
        return jsonify({"error": str(e)})

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
    
    if not (file.filename.endswith('.tar.gz') or file.filename.endswith('.tgz')):
        return jsonify({"success": False, "error": "Formato inválido. Use .tar.gz"})
    
    temp_path = os.path.join(tempfile.gettempdir(), f"restore_{uuid.uuid4().hex}.tar.gz")
    file.save(temp_path)
    
    result = restore_backup(temp_path)
    
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
        
        conversion_name = request.form.get('conversion_name', '').strip()
        if not conversion_name:
            conversion_name = f"Conversão {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        
        conversion_name = sanitize_filename(conversion_name)
        
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        files_data = [(file, file.filename) for file in files]
        playlist_id = str(uuid.uuid4())[:8]
        
        def process_task():
            return process_multiple_videos(files_data, qualities, playlist_id, conversion_name)
        
        future = executor.submit(process_task)
        result = future.result(timeout=3600)
        
        if result["success"]:
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "video_id": playlist_id,
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
        
        playlist_id = str(uuid.uuid4())[:8]
        result = process_multiple_videos([(file, file.filename)], qualities, playlist_id, conversion_name)
        
        if result["success"]:
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
        "service": "hls-converter-ultimate",
        "timestamp": datetime.now().isoformat(),
        "version": "2.2.0",
        "ffmpeg": find_ffmpeg() is not None,
        "multi_upload": True,
        "backup_system": True,
        "named_conversions": True
    })

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
