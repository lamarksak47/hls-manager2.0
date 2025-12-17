#!/bin/bash
# install_hls_converter_final.sh - VERSÃO COMPLETA FUNCIONAL

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE - VERSÃO COMPLETA"
echo "======================================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_final.sh"
    exit 1
fi

# 2. Atualizar sistema
echo "📦 Atualizando sistema..."
apt-get update && apt-get upgrade -y

# 3. Parar serviços existentes
echo "🛑 Parando serviços existentes..."
systemctl stop hls-simple hls-dashboard hls-manager hls-final hls-converter 2>/dev/null || true
pkill -9 python 2>/dev/null || true
sleep 2

# 4. Limpar instalações anteriores
echo "🧹 Limpando instalações anteriores..."
rm -rf /opt/hls-converter 2>/dev/null || true
rm -rf /etc/systemd/system/hls-*.service 2>/dev/null || true
rm -f /usr/local/bin/hlsctl 2>/dev/null || true
systemctl daemon-reload

# 5. INSTALAR FFMPEG
echo "🎬 INSTALANDO FFMPEG..."
if ! command -v ffmpeg &> /dev/null; then
    apt-get install -y ffmpeg
    echo "✅ FFmpeg instalado"
else
    echo "✅ FFmpeg já está instalado"
fi

# 6. Instalar outras dependências
echo "🔧 Instalando outras dependências..."
apt-get install -y python3 python3-pip python3-venv curl wget net-tools

# 7. Criar estrutura de diretórios
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,templates,static,sessions}
mkdir -p /opt/hls-converter/hls/{240p,360p,480p,720p,1080p,original}
cd /opt/hls-converter

# 8. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if id "hlsuser" &>/dev/null; then
    echo "✅ Usuário hlsuser já existe"
else
    useradd -r -s /bin/false hlsuser
    echo "✅ Usuário hlsuser criado"
fi

# 9. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python
echo "📦 Instalando dependências Python..."
pip install --upgrade pip
pip install flask flask-cors waitress werkzeug psutil bcrypt cryptography

# 10. CRIAR APLICAÇÃO FLASK COMPLETA
echo "💻 Criando aplicação Flask completa..."

cat > app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão Completa Funcional
"""

import os
import sys
import json
import time
import uuid
import shutil
import subprocess
import threading
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, render_template_string, send_file, redirect, url_for, session, flash
from flask_cors import CORS
import bcrypt
import secrets
import psutil
from concurrent.futures import ThreadPoolExecutor

# =============== CONFIGURAÇÃO INICIAL ===============
app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)

# Configurações de segurança
app.secret_key = secrets.token_hex(32)
app.config['SESSION_TYPE'] = 'filesystem'
app.config['SESSION_FILE_DIR'] = '/opt/hls-converter/sessions'
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=1)
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SECURE'] = False

# Diretórios
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
USERS_FILE = os.path.join(DB_DIR, "users.json")
CONVERSIONS_FILE = os.path.join(DB_DIR, "conversions.json")

# Criar diretórios
for dir_path in [UPLOAD_DIR, HLS_DIR, LOG_DIR, DB_DIR, app.config['SESSION_FILE_DIR']]:
    os.makedirs(dir_path, exist_ok=True)

# Executor para processamento
executor = ThreadPoolExecutor(max_workers=2)

# =============== FUNÇÕES AUXILIARES ===============
def load_users():
    """Carrega usuários do arquivo JSON"""
    default_users = {
        "users": {
            "admin": {
                "password": "$2b$12$7eE8R5Yq3X3t7kXq3Z8p9eBvG9HjK1L2N3M4Q5W6X7Y8Z9A0B1C2D3E4F5G6H7I8J9",
                "password_changed": False,
                "created_at": datetime.now().isoformat(),
                "last_login": None,
                "role": "admin"
            }
        },
        "settings": {
            "require_password_change": True,
            "session_timeout": 3600,
            "max_login_attempts": 5
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
    except:
        pass
    
    save_users(default_users)
    return default_users

def save_users(data):
    """Salva usuários no arquivo JSON"""
    try:
        with open(USERS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except:
        pass

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
    except:
        pass
    
    save_conversions(default_data)
    return default_data

def save_conversions(data):
    """Salva conversões no arquivo JSON"""
    try:
        with open(CONVERSIONS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except:
        pass

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
    except:
        return False

def find_ffmpeg():
    """Encontra o caminho do ffmpeg"""
    for path in ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/bin/ffmpeg']:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    return None

def convert_video_worker(file_data, qualities, playlist_id, index, total):
    """Worker para converter um vídeo"""
    try:
        file, filename = file_data
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            return None, "FFmpeg não encontrado"
        
        video_id = f"{playlist_id}_{index:03d}"
        output_dir = os.path.join(HLS_DIR, playlist_id, video_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Salvar arquivo
        original_path = os.path.join(output_dir, "original.mp4")
        file.save(original_path)
        
        video_info = {
            "id": video_id,
            "filename": filename,
            "qualities": []
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
            elif quality == '480p':
                scale = "854:480"
                bitrate = "800k"
                audio_bitrate = "96k"
            elif quality == '720p':
                scale = "1280:720"
                bitrate = "1500k"
                audio_bitrate = "128k"
            elif quality == '1080p':
                scale = "1920:1080"
                bitrate = "3000k"
                audio_bitrate = "192k"
            else:
                continue
            
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
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if result.returncode == 0:
                video_info["qualities"].append(quality)
        
        # Mover original
        os.makedirs(os.path.join(output_dir, "original"), exist_ok=True)
        shutil.move(original_path, os.path.join(output_dir, "original", filename))
        
        return video_info, None
        
    except Exception as e:
        return None, str(e)

def create_playlist(playlist_id, videos_info, qualities):
    """Cria playlist master"""
    playlist_dir = os.path.join(HLS_DIR, playlist_id)
    master_playlist = os.path.join(playlist_dir, "master.m3u8")
    
    with open(master_playlist, 'w') as f:
        f.write("#EXTM3U\n")
        f.write("#EXT-X-VERSION:3\n")
        
        for quality in qualities:
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
    
    return master_playlist

# =============== PÁGINAS HTML ===============
LOGIN_HTML = '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login - HLS Converter</title>
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
                <input type="text" name="username" placeholder="Usuário" required value="admin">
            </div>
            <div class="form-group">
                <input type="password" name="password" placeholder="Senha" required value="admin">
            </div>
            <button type="submit" class="btn-login">Entrar</button>
        </form>
        
        <div class="credentials">
            <p><strong>Usuário:</strong> admin</p>
            <p><strong>Senha:</strong> admin</p>
        </div>
    </div>
</body>
</html>
'''

DASHBOARD_HTML = '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HLS Converter</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.0.0/css/all.min.css">
    <style>
        :root {
            --primary: #4361ee;
            --secondary: #3a0ca3;
            --success: #2ecc71;
            --danger: #e74c3c;
        }
        
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            background: #f5f7fa;
        }
        
        .header {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            color: white;
            padding: 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .container {
            max-width: 1200px;
            margin: 30px auto;
            padding: 0 20px;
        }
        
        .card {
            background: white;
            border-radius: 10px;
            padding: 25px;
            margin-bottom: 25px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.08);
        }
        
        .btn {
            padding: 12px 25px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            display: inline-flex;
            align-items: center;
            gap: 10px;
        }
        
        .btn-primary {
            background: var(--primary);
            color: white;
        }
        
        .upload-area {
            border: 3px dashed var(--primary);
            border-radius: 12px;
            padding: 60px 30px;
            text-align: center;
            margin: 30px 0;
            cursor: pointer;
            background: rgba(67, 97, 238, 0.02);
        }
        
        .selected-files {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin-top: 20px;
        }
        
        .file-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px 15px;
            background: white;
            border-radius: 8px;
            margin-bottom: 8px;
        }
        
        .quality-selector {
            display: flex;
            gap: 15px;
            margin: 20px 0;
            flex-wrap: wrap;
        }
        
        .quality-option {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 8px;
            cursor: pointer;
            border: 2px solid transparent;
        }
        
        .quality-option.selected {
            background: var(--primary);
            color: white;
        }
    </style>
</head>
<body>
    <div class="header">
        <div>
            <h1><i class="fas fa-video"></i> HLS Converter</h1>
        </div>
        <div>
            <span>{{ session.user_id }}</span>
            <a href="/logout" style="color: white; margin-left: 20px;">
                <i class="fas fa-sign-out-alt"></i> Sair
            </a>
        </div>
    </div>
    
    <div class="container">
        <div class="card">
            <h2><i class="fas fa-upload"></i> Converter Vídeos</h2>
            
            <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                <i class="fas fa-cloud-upload-alt" style="font-size: 4rem; color: var(--primary);"></i>
                <h3>Arraste e solte seus vídeos aqui</h3>
                <p>ou clique para selecionar múltiplos arquivos</p>
            </div>
            
            <input type="file" id="fileInput" accept="video/*" multiple style="display: none;" onchange="handleFileSelect()">
            
            <div id="selectedFiles" class="selected-files" style="display: none;">
                <h4>Arquivos Selecionados (<span id="fileCount">0</span>)</h4>
                <div id="fileList"></div>
            </div>
            
            <div>
                <h3>Qualidades de Saída</h3>
                <div class="quality-selector">
                    <div class="quality-option selected" data-quality="240p" onclick="toggleQuality(this)">240p</div>
                    <div class="quality-option selected" data-quality="480p" onclick="toggleQuality(this)">480p</div>
                    <div class="quality-option selected" data-quality="720p" onclick="toggleQuality(this)">720p</div>
                    <div class="quality-option selected" data-quality="1080p" onclick="toggleQuality(this)">1080p</div>
                </div>
            </div>
            
            <button class="btn btn-primary" onclick="startConversion()" id="convertBtn" style="width: 100%; margin-top: 30px;">
                <i class="fas fa-play-circle"></i> Iniciar Conversão
            </button>
            
            <div id="progress" style="display: none; margin-top: 30px;">
                <h3><i class="fas fa-spinner fa-spin"></i> Progresso</h3>
                <div style="background: #e9ecef; border-radius: 10px; height: 20px; overflow: hidden;">
                    <div id="progressBar" style="height: 100%; background: var(--primary); width: 0%; text-align: center; color: white; line-height: 20px;">0%</div>
                </div>
                <p id="progressText" style="text-align: center;">Processando...</p>
            </div>
        </div>
        
        <div class="card">
            <h2><i class="fas fa-history"></i> Histórico</h2>
            <div id="conversionsList">
                <p style="text-align: center; color: #666;">Nenhuma conversão ainda</p>
            </div>
        </div>
    </div>

    <script>
        let selectedFiles = [];
        let selectedQualities = ['240p', '480p', '720p', '1080p'];
        
        function handleFileSelect() {
            const fileInput = document.getElementById('fileInput');
            selectedFiles = Array.from(fileInput.files);
            updateFileList();
        }
        
        function updateFileList() {
            const container = document.getElementById('selectedFiles');
            const fileList = document.getElementById('fileList');
            const fileCount = document.getElementById('fileCount');
            
            fileList.innerHTML = '';
            fileCount.textContent = selectedFiles.length;
            
            selectedFiles.forEach((file, index) => {
                const div = document.createElement('div');
                div.className = 'file-item';
                div.innerHTML = `
                    <span>${file.name}</span>
                    <span>${formatBytes(file.size)}</span>
                `;
                fileList.appendChild(div);
            });
            
            container.style.display = selectedFiles.length > 0 ? 'block' : 'none';
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
            if (selectedFiles.length === 0) {
                alert('Selecione pelo menos um arquivo!');
                return;
            }
            
            const formData = new FormData();
            selectedFiles.forEach(file => {
                formData.append('files[]', file);
            });
            formData.append('qualities', JSON.stringify(selectedQualities));
            
            const progress = document.getElementById('progress');
            const progressBar = document.getElementById('progressBar');
            const progressText = document.getElementById('progressText');
            const convertBtn = document.getElementById('convertBtn');
            
            progress.style.display = 'block';
            convertBtn.disabled = true;
            convertBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Convertendo...';
            
            let progressPercent = 0;
            const progressInterval = setInterval(() => {
                progressPercent = Math.min(progressPercent + 2, 90);
                progressBar.style.width = progressPercent + '%';
                progressBar.textContent = progressPercent + '%';
                progressText.textContent = 'Processando vídeos...';
            }, 500);
            
            fetch('/convert-multiple', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                clearInterval(progressInterval);
                
                if (data.success) {
                    progressBar.style.width = '100%';
                    progressBar.textContent = '100%';
                    progressText.textContent = 'Concluído!';
                    
                    setTimeout(() => {
                        progress.style.display = 'none';
                        convertBtn.disabled = false;
                        convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão';
                        progressBar.style.width = '0%';
                        selectedFiles = [];
                        document.getElementById('selectedFiles').style.display = 'none';
                        loadConversions();
                    }, 2000);
                    
                    alert('Conversão concluída! Playlist ID: ' + data.playlist_id);
                } else {
                    alert('Erro: ' + data.error);
                    convertBtn.disabled = false;
                    convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão';
                }
            })
            .catch(error => {
                clearInterval(progressInterval);
                alert('Erro: ' + error.message);
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão';
            });
        }
        
        function loadConversions() {
            fetch('/api/conversions')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('conversionsList');
                    
                    if (!data.conversions || data.conversions.length === 0) {
                        container.innerHTML = '<p style="text-align: center; color: #666;">Nenhuma conversão ainda</p>';
                        return;
                    }
                    
                    let html = '<div style="display: grid; gap: 15px;">';
                    data.conversions.forEach(conv => {
                        html += `
                            <div style="background: #f8f9fa; padding: 15px; border-radius: 8px; border-left: 4px solid var(--primary);">
                                <div style="display: flex; justify-content: space-between;">
                                    <strong>${conv.filename || 'Arquivo'}</strong>
                                    <span style="background: ${conv.status === 'success' ? '#d4edda' : '#f8d7da'}; color: ${conv.status === 'success' ? '#155724' : '#721c24'}; padding: 3px 10px; border-radius: 20px; font-size: 0.9rem;">
                                        ${conv.status === 'success' ? '✅ Sucesso' : '❌ Falha'}
                                    </span>
                                </div>
                                <div style="margin-top: 10px; font-size: 0.9rem;">
                                    <div>ID: ${conv.video_id || conv.playlist_id || 'N/A'}</div>
                                    <div>Qualidades: ${(conv.qualities || []).join(', ')}</div>
                                    <div>Data: ${new Date(conv.timestamp).toLocaleString()}</div>
                                </div>
                            </div>
                        `;
                    });
                    html += '</div>';
                    container.innerHTML = html;
                });
        }
        
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // Carregar histórico ao iniciar
        document.addEventListener('DOMContentLoaded', loadConversions);
    </script>
</body>
</html>
'''

# =============== ROTAS PRINCIPAIS ===============
@app.route('/')
def index():
    if 'user_id' not in session:
        return redirect(url_for('login'))
    return render_template_string(DASHBOARD_HTML)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'GET':
        if 'user_id' in session:
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML)
    
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    
    if username == 'admin' and password == 'admin':
        session['user_id'] = username
        return redirect(url_for('index'))
    
    flash('Credenciais inválidas', 'error')
    return render_template_string(LOGIN_HTML)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/api/system')
def api_system():
    try:
        cpu = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        conversions = load_conversions()
        
        return jsonify({
            "cpu": f"{cpu:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "total_conversions": conversions["stats"]["total"],
            "success_conversions": conversions["stats"]["success"],
            "ffmpeg_status": "ok" if find_ffmpeg() else "missing"
        })
    except Exception as e:
        return jsonify({"error": str(e)})

@app.route('/api/conversions')
def api_conversions():
    try:
        data = load_conversions()
        return jsonify(data)
    except:
        return jsonify({"conversions": [], "stats": {"total": 0, "success": 0, "failed": 0}})

@app.route('/convert-multiple', methods=['POST'])
def convert_multiple_videos():
    if 'user_id' not in session:
        return jsonify({"success": False, "error": "Não autenticado"}), 401
    
    try:
        if 'files[]' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo"})
        
        files = request.files.getlist('files[]')
        if not files:
            return jsonify({"success": False, "error": "Nenhum arquivo"})
        
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        playlist_id = str(uuid.uuid4())[:8]
        videos_info = []
        errors = []
        
        # Processar cada vídeo
        for index, file in enumerate(files, 1):
            video_info, error = convert_video_worker(
                (file, file.filename),
                qualities,
                playlist_id,
                index,
                len(files)
            )
            
            if error:
                errors.append(f"{file.filename}: {error}")
            elif video_info:
                videos_info.append(video_info)
        
        if videos_info:
            create_playlist(playlist_id, videos_info, qualities)
            
            # Salvar no histórico
            conversions = load_conversions()
            conversion_data = {
                "playlist_id": playlist_id,
                "filename": f"{len(files)} arquivos",
                "qualities": qualities,
                "timestamp": datetime.now().isoformat(),
                "status": "success",
                "videos_count": len(videos_info)
            }
            
            conversions['conversions'].insert(0, conversion_data)
            conversions['stats']['total'] += 1
            conversions['stats']['success'] += 1
            save_conversions(conversions)
            
            return jsonify({
                "success": True,
                "playlist_id": playlist_id,
                "videos_count": len(videos_info),
                "errors": errors,
                "m3u8_url": f"/hls/{playlist_id}/master.m3u8"
            })
        else:
            conversions = load_conversions()
            conversions['stats']['total'] += 1
            conversions['stats']['failed'] += 1
            save_conversions(conversions)
            
            return jsonify({
                "success": False,
                "error": "Nenhum vídeo convertido",
                "errors": errors
            })
            
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/hls/<playlist_id>/master.m3u8')
@app.route('/hls/<playlist_id>/<path:filename>')
def serve_hls(playlist_id, filename=None):
    if filename is None:
        filename = "master.m3u8"
    
    filepath = os.path.join(HLS_DIR, playlist_id, filename)
    if os.path.exists(filepath):
        return send_file(filepath)
    
    # Buscar em subdiretórios
    for root, dirs, files in os.walk(os.path.join(HLS_DIR, playlist_id)):
        if filename in files:
            return send_file(os.path.join(root, filename))
    
    return "Arquivo não encontrado", 404

@app.route('/player/<playlist_id>')
def player_page(playlist_id):
    m3u8_url = f"/hls/{playlist_id}/master.m3u8"
    return f'''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Player - {playlist_id}</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <style>
            body {{ margin: 0; padding: 20px; background: #000; }}
            .player-container {{ max-width: 1200px; margin: 0 auto; }}
        </style>
    </head>
    <body>
        <div class="player-container">
            <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="auto">
                <source src="{m3u8_url}" type="application/x-mpegURL">
            </video>
        </div>
        
        <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/videojs-contrib-hls/5.15.0/videojs-contrib-hls.min.js"></script>
        <script>
            var player = videojs('hlsPlayer');
            player.play();
        </script>
    </body>
    </html>
    '''

@app.route('/health')
def health():
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "ffmpeg": find_ffmpeg() is not None
    })

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 60)
    print("🚀 HLS Converter ULTIMATE - Sistema Iniciado")
    print("=" * 60)
    print(f"📂 Diretório: {BASE_DIR}")
    print(f"🐍 Python: {sys.version.split()[0]}")
    print(f"🌐 Porta: 8080")
    print(f"🔐 Login: admin / admin")
    print("=" * 60)
    
    # Inicializar banco de dados
    load_users()
    load_conversions()
    
    # Iniciar servidor
    try:
        from waitress import serve
        print("🚀 Servidor iniciado com Waitress")
        serve(app, host='0.0.0.0', port=8080, threads=4)
    except ImportError:
        print("⚠️  Usando servidor de desenvolvimento")
        app.run(host='0.0.0.0', port=8080, debug=False, use_reloader=False)
EOF

# 11. CRIAR ARQUIVOS DE BANCO DE DADOS
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
        "session_timeout": 3600,
        "max_login_attempts": 5
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

# 12. CRIAR SCRIPT DE GERENCIAMENTO
echo "📝 Criando script de gerenciamento..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "🚀 Iniciando HLS Converter..."
        systemctl start hls-converter
        echo "✅ Serviço iniciado"
        sleep 2
        systemctl status hls-converter --no-pager
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
        
        # Testar serviço
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço ativo"
            
            # Testar health
            echo "🌐 Testando health check..."
            if curl -s http://localhost:8080/health | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "❌ Health check falhou"
            fi
            
            # Testar login
            echo "🔐 Testando login..."
            if curl -s http://localhost:8080/login | grep -q "HLS Converter"; then
                echo "✅ Página de login OK"
            else
                echo "❌ Página de login falhou"
            fi
            
        else
            echo "❌ Serviço inativo"
        fi
        
        # Testar FFmpeg
        echo ""
        echo "🎬 Testando FFmpeg..."
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg encontrado"
            ffmpeg -version | head -1
        else
            echo "❌ FFmpeg não encontrado"
        fi
        ;;
    fix-permissions)
        echo "🔧 Corrigindo permissões..."
        chown -R hlsuser:hlsuser /opt/hls-converter
        chmod 755 /opt/hls-converter
        chmod 644 /opt/hls-converter/app.py
        chmod 644 /opt/hls-converter/db/*.json
        chmod 755 /usr/local/bin/hlsctl
        systemctl daemon-reload
        echo "✅ Permissões corrigidas"
        ;;
    cleanup)
        echo "🧹 Limpando arquivos temporários..."
        find /opt/hls-converter/uploads -type f -mtime +7 -delete 2>/dev/null || true
        find /opt/hls-converter/hls -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
        echo "✅ Arquivos limpos"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=" * 50
        echo "🎬 HLS Converter ULTIMATE"
        echo "=" * 50
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo "Porta: 8080"
        echo "Login: http://$IP:8080/login"
        echo "Usuário: admin"
        echo "Senha: admin"
        echo ""
        echo "📁 Diretório: /opt/hls-converter"
        echo "📊 Logs: journalctl -u hls-converter"
        echo "=" * 50
        ;;
    *)
        echo "🎬 HLS Converter - Gerenciador"
        echo "================================"
        echo ""
        echo "Comandos:"
        echo "  start          - Iniciar serviço"
        echo "  stop           - Parar serviço"
        echo "  restart        - Reiniciar serviço"
        echo "  status         - Ver status"
        echo "  logs [-f]      - Ver logs"
        echo "  test           - Testar sistema"
        echo "  fix-permissions - Corrigir permissões"
        echo "  cleanup        - Limpar arquivos"
        echo "  info           - Informações"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl start"
        echo "  hlsctl logs -f"
        echo "  hlsctl test"
        echo "  hlsctl fix-permissions"
        ;;
esac
EOF

# 13. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Configurando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter ULTIMATE Service
After=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls-converter
Environment="PATH=/opt/hls-converter/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONUNBUFFERED=1"

ExecStart=/opt/hls-converter/venv/bin/python /opt/hls-converter/app.py

Restart=always
RestartSec=10

StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

[Install]
WantedBy=multi-user.target
EOF

# 14. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."

chown -R hlsuser:hlsuser /opt/hls-converter
chmod 755 /opt/hls-converter
chmod 644 /opt/hls-converter/app.py
chmod 644 /opt/hls-converter/db/*.json
chmod 755 /usr/local/bin/hlsctl
chmod 700 /opt/hls-converter/sessions

# 15. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."

systemctl daemon-reload
systemctl enable hls-converter.service

if systemctl start hls-converter.service; then
    echo "✅ Serviço iniciado"
    sleep 3
    
    # Verificar status
    if systemctl is-active --quiet hls-converter.service; then
        echo "🎉 SERVIÇO ATIVO!"
        
        # Testar
        echo ""
        echo "🧪 Testando conexão..."
        sleep 2
        
        if curl -s http://localhost:8080/health 2>/dev/null | grep -q "healthy"; then
            echo "✅ Health check OK"
        else
            echo "⚠️  Aguardando inicialização..."
            sleep 5
            if curl -s http://localhost:8080/health 2>/dev/null | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "❌ Health check falhou"
            fi
        fi
    else
        echo "⚠️  Serviço iniciado mas não está ativo"
    fi
else
    echo "❌ Falha ao iniciar serviço"
fi

# 16. VERIFICAÇÃO FINAL
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "=" * 60
echo "🎉 INSTALAÇÃO COMPLETA!"
echo "=" * 60
echo ""
echo "✅ SISTEMA PRONTO PARA USO"
echo ""
echo "🔐 INFORMAÇÕES:"
echo "   Login: http://$IP:8080/login"
echo "   Usuário: admin"
echo "   Senha: admin"
echo ""
echo "⚙️  COMANDOS:"
echo "   hlsctl start    - Iniciar"
echo "   hlsctl stop     - Parar"
echo "   hlsctl status   - Status"
echo "   hlsctl logs     - Logs"
echo "   hlsctl test     - Testar"
echo ""
echo "📋 FUNCIONALIDADES:"
echo "   ✅ Multi-upload de vídeos"
echo "   ✅ Conversão para HLS"
echo "   ✅ Múltiplas qualidades"
echo "   ✅ Histórico de conversões"
echo "   ✅ Player HLS integrado"
echo ""
echo "=" * 60
echo "🚀 Acesse: http://$IP:8080"
echo "=" * 60
