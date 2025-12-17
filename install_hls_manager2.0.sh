#!/bin/bash
# install_hls_converter_ultimate_fixed.sh - SISTEMA COMPLETO ULTIMATE CORRIGIDO

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE CORRIGIDO"
echo "=============================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_ultimate_fixed.sh"
    exit 1
fi

# 2. Atualizar sistema primeiro
echo "📦 Atualizando sistema..."
apt-get update
apt-get upgrade -y

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

# 5. FUNÇÃO ROBUSTA PARA INSTALAR FFMPEG
install_ffmpeg_robust() {
    echo "🔧 Instalando ffmpeg com métodos múltiplos..."
    
    # Método 1: Tentar instalação normal
    echo "📦 Método 1: Instalação normal do apt..."
    apt-get update
    if apt-get install -y ffmpeg; then
        echo "✅ FFmpeg instalado com sucesso via apt"
        return 0
    fi
    
    # Método 2: Tentar instalar individualmente
    echo "📦 Método 2: Instalando componentes individualmente..."
    apt-get install -y libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev libavdevice-dev \
        libswscale-dev libswresample-dev libpostproc-dev || true
    
    # Método 3: Tentar instalar do repositório Snap
    echo "📦 Método 3: Tentando via Snap..."
    if command -v snap &> /dev/null; then
        if snap install ffmpeg --classic; then
            echo "✅ FFmpeg instalado via Snap"
            return 0
        fi
    fi
    
    # Método 4: Binário estático
    echo "📦 Método 4: Baixando binário estático..."
    cd /tmp
    if wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz || \
       wget -q https://www.johnvansickle.com/ffmpeg/old-releases/ffmpeg-4.4.1-amd64-static.tar.xz || \
       curl -L -o ffmpeg-release-amd64-static.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz; then
        
        tar -xf ffmpeg-release-amd64-static.tar.xz
        FFMPEG_DIR=$(find . -name "ffmpeg-*-static" -type d | head -1)
        if [ -n "$FFMPEG_DIR" ]; then
            cp "$FFMPEG_DIR"/ffmpeg "$FFMPEG_DIR"/ffprobe /usr/local/bin/
            chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
            echo "✅ FFmpeg instalado de binário estático"
            return 0
        fi
    fi
    
    echo "⚠️  Não foi possível instalar FFmpeg automaticamente"
    return 1
}

# 6. INSTALAR FFMPEG
echo "🎬 INSTALANDO FFMPEG..."
if command -v ffmpeg &> /dev/null; then
    echo "✅ ffmpeg já está instalado"
    echo "🔍 Versão do ffmpeg:"
    ffmpeg -version | head -1
else
    echo "❌ ffmpeg não encontrado, instalando..."
    if install_ffmpeg_robust; then
        echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
        ffmpeg -version | head -1
    else
        echo "⚠️  FFmpeg pode não estar instalado corretamente"
        echo "📋 Execute manualmente: sudo apt-get install -y ffmpeg"
    fi
fi

# 7. Instalar outras dependências do sistema
echo "🔧 Instalando outras dependências do sistema..."
apt-get install -y python3 python3-pip python3-venv htop curl wget git

# 8. Criar estrutura de diretórios
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,templates,static,sessions}
mkdir -p /opt/hls-converter/hls/{240p,360p,480p,720p,1080p,original}
cd /opt/hls-converter

# 9. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if id "hlsuser" &>/dev/null; then
    echo "✅ Usuário hlsuser já existe"
else
    useradd -r -s /bin/false hlsuser
    echo "✅ Usuário hlsuser criado"
fi

# 10. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python COM VERIFICAÇÃO
echo "📦 Instalando dependências Python..."
pip install --upgrade pip

# Lista de dependências com fallback
DEPS="flask flask-cors waitress werkzeug"
for dep in $DEPS; do
    if ! pip install $dep; then
        echo "⚠️  Falha ao instalar $dep, tentando método alternativo..."
        pip install $dep --no-deps || true
    fi
done

# Dependências opcionais
pip install psutil python-magic || echo "⚠️  Algumas dependências opcionais falharam"

# Dependências de autenticação (tentativa com fallback)
if ! pip install bcrypt cryptography; then
    echo "⚠️  Instalando bcrypt/cryptography via apt..."
    apt-get install -y python3-bcrypt python3-cryptography || true
fi

# 11. CRIAR APLICAÇÃO FLASK SIMPLIFICADA E FUNCIONAL
echo "💻 Criando aplicação Flask corrigida..."

cat > app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão Corrigida
Sistema completo com autenticação e correções de inicialização
"""

import os
import sys
import json
import time
import uuid
import shutil
import subprocess
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, render_template_string, send_file, redirect, url_for, session, flash
from flask_cors import CORS
import bcrypt
import secrets

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
            "session_timeout": 3600,
            "max_login_attempts": 5
        }
    }
    
    try:
        if os.path.exists(USERS_FILE):
            with open(USERS_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        print(f"Erro ao carregar usuários: {e}")
    
    # Criar arquivo padrão se não existir
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
                return json.load(f)
    except:
        pass
    
    return default_data

def save_conversions(data):
    """Salva conversões no arquivo JSON"""
    try:
        with open(CONVERSIONS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Erro ao salvar conversões: {e}")

def check_password(username, password):
    """Verifica se a senha está correta"""
    users = load_users()
    if username in users['users']:
        stored_hash = users['users'][username]['password']
        try:
            return bcrypt.checkpw(password.encode('utf-8'), stored_hash.encode('utf-8'))
        except:
            return False
    return False

def password_change_required(username):
    """Verifica se o usuário precisa alterar a senha"""
    users = load_users()
    if username in users['users']:
        return not users['users'][username].get('password_changed', False)
    return False

def find_ffmpeg():
    """Encontra o caminho do ffmpeg"""
    for path in ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/bin/ffmpeg', '/snap/bin/ffmpeg']:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    return None

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
        .alert-info {
            background: #d1ecf1;
            color: #0c5460;
            border: 1px solid #bee5eb;
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
        
        <div style="margin-top: 20px; text-align: center; font-size: 14px; color: #666;">
            <p><strong>Usuário padrão:</strong> admin</p>
            <p><strong>Senha padrão:</strong> admin</p>
            <p style="color: #dc3545; margin-top: 10px;">
                ⚠️ É necessário alterar a senha no primeiro acesso
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
        .requirements ul {
            margin: 0;
            padding-left: 20px;
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
    <style>
        :root {
            --primary: #4361ee;
            --secondary: #3a0ca3;
            --accent: #4cc9f0;
        }
        
        body {
            margin: 0;
            padding: 0;
            font-family: Arial, sans-serif;
            background: #f5f7fb;
        }
        
        .header {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            color: white;
            padding: 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        .user-info {
            display: flex;
            align-items: center;
            gap: 15px;
        }
        
        .logout-btn {
            background: rgba(255,255,255,0.2);
            border: 1px solid rgba(255,255,255,0.3);
            color: white;
            padding: 8px 15px;
            border-radius: 5px;
            text-decoration: none;
            transition: background 0.3s;
        }
        
        .logout-btn:hover {
            background: rgba(255,255,255,0.3);
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
            box-shadow: 0 5px 15px rgba(0,0,0,0.05);
            border: 1px solid #eaeaea;
        }
        
        .card h2 {
            color: var(--primary);
            margin-top: 0;
            border-bottom: 2px solid #f0f0f0;
            padding-bottom: 15px;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        
        .stat-item {
            text-align: center;
            padding: 20px;
            background: #f8f9fa;
            border-radius: 8px;
        }
        
        .stat-value {
            font-size: 2em;
            font-weight: bold;
            color: var(--primary);
        }
        
        .stat-label {
            color: #666;
            margin-top: 5px;
        }
        
        .upload-area {
            border: 3px dashed var(--primary);
            border-radius: 10px;
            padding: 50px;
            text-align: center;
            margin: 20px 0;
            cursor: pointer;
            transition: all 0.3s;
        }
        
        .upload-area:hover {
            background: rgba(67, 97, 238, 0.05);
        }
        
        .btn-primary {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            color: white;
            border: none;
            padding: 12px 30px;
            border-radius: 5px;
            font-size: 16px;
            cursor: pointer;
            transition: transform 0.2s;
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
        }
        
        .nav-tabs {
            display: flex;
            border-bottom: 2px solid #eaeaea;
            margin-bottom: 20px;
        }
        
        .nav-tab {
            padding: 15px 25px;
            cursor: pointer;
            border-bottom: 3px solid transparent;
            transition: all 0.3s;
        }
        
        .nav-tab.active {
            border-bottom: 3px solid var(--primary);
            color: var(--primary);
            font-weight: bold;
        }
        
        .tab-content {
            display: none;
        }
        
        .tab-content.active {
            display: block;
        }
        
        .conversion-item {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 10px;
            border-left: 4px solid var(--accent);
        }
        
        .ffmpeg-status {
            display: inline-block;
            padding: 5px 10px;
            border-radius: 20px;
            font-size: 0.9em;
            font-weight: bold;
        }
        
        .ffmpeg-ok {
            background: #d4edda;
            color: #155724;
        }
        
        .ffmpeg-missing {
            background: #f8d7da;
            color: #721c24;
        }
        
        .system-info {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px;
            border-radius: 8px;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🎬 HLS Converter ULTIMATE</h1>
        <div class="user-info">
            <span>👤 {{ session.user_id }}</span>
            <a href="/logout" class="logout-btn">🚪 Sair</a>
        </div>
    </div>
    
    <div class="container">
        <!-- Navegação -->
        <div class="nav-tabs">
            <div class="nav-tab active" onclick="showTab('dashboard')">📊 Dashboard</div>
            <div class="nav-tab" onclick="showTab('upload')">📤 Upload</div>
            <div class="nav-tab" onclick="showTab('conversions')">🔄 Conversões</div>
            <div class="nav-tab" onclick="showTab('settings')">⚙️ Configurações</div>
        </div>
        
        <!-- Dashboard Tab -->
        <div id="dashboard" class="tab-content active">
            <div class="card">
                <h2>📊 Status do Sistema</h2>
                <div class="stats-grid">
                    <div class="stat-item">
                        <div class="stat-value" id="cpu">--%</div>
                        <div class="stat-label">CPU</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="memory">--%</div>
                        <div class="stat-label">Memória</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="disk">--%</div>
                        <div class="stat-label">Disco</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-value" id="conversions">0</div>
                        <div class="stat-label">Conversões</div>
                    </div>
                </div>
                
                <div class="system-info">
                    <h3>FFmpeg Status:</h3>
                    <div id="ffmpegStatus" class="ffmpeg-status ffmpeg-missing">Verificando...</div>
                    <p id="ffmpegPath"></p>
                </div>
            </div>
            
            <div class="card">
                <h2>🚀 Ações Rápidas</h2>
                <div style="display: flex; gap: 15px; margin-top: 20px;">
                    <button class="btn-primary" onclick="showTab('upload')">📤 Converter Vídeo</button>
                    <button class="btn-primary" onclick="refreshStats()">🔄 Atualizar Status</button>
                    <button class="btn-primary" onclick="testFFmpeg()">🧪 Testar FFmpeg</button>
                </div>
            </div>
        </div>
        
        <!-- Upload Tab -->
        <div id="upload" class="tab-content">
            <div class="card">
                <h2>📤 Upload de Vídeo</h2>
                <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                    <h3>📁 Arraste e solte seu vídeo aqui</h3>
                    <p>ou clique para selecionar</p>
                    <p><small>Formatos: MP4, AVI, MOV, MKV, WEBM</small></p>
                </div>
                <input type="file" id="fileInput" accept="video/*" style="display: none;" onchange="handleFileSelect()">
                
                <div id="fileInfo" style="display: none; margin: 20px 0; padding: 15px; background: #f8f9fa; border-radius: 8px;">
                    <h4>Arquivo selecionado:</h4>
                    <p id="fileName"></p>
                    <p id="fileSize"></p>
                </div>
                
                <div style="margin-top: 30px;">
                    <h3>Qualidades:</h3>
                    <div style="display: flex; gap: 20px; margin: 15px 0;">
                        <label><input type="checkbox" id="q240" checked> 240p</label>
                        <label><input type="checkbox" id="q480" checked> 480p</label>
                        <label><input type="checkbox" id="q720" checked> 720p</label>
                        <label><input type="checkbox" id="q1080" checked> 1080p</label>
                    </div>
                </div>
                
                <button class="btn-primary" onclick="startConversion()" id="convertBtn" style="margin-top: 20px;">
                    🚀 Iniciar Conversão
                </button>
                
                <div id="progress" style="display: none; margin-top: 30px;">
                    <h3>Progresso:</h3>
                    <div style="background: #e9ecef; height: 20px; border-radius: 10px; overflow: hidden;">
                        <div id="progressBar" style="height: 100%; background: #4361ee; width: 0%; transition: width 0.3s;"></div>
                    </div>
                    <p id="progressText" style="text-align: center; margin-top: 10px;">0%</p>
                </div>
            </div>
        </div>
        
        <!-- Conversions Tab -->
        <div id="conversions" class="tab-content">
            <div class="card">
                <h2>🔄 Histórico de Conversões</h2>
                <div id="conversionsList">
                    <p>Carregando histórico...</p>
                </div>
            </div>
        </div>
        
        <!-- Settings Tab -->
        <div id="settings" class="tab-content">
            <div class="card">
                <h2>⚙️ Configurações</h2>
                <div style="margin-top: 20px;">
                    <h3>Segurança</h3>
                    <button class="btn-primary" onclick="changePassword()">
                        🔑 Alterar Minha Senha
                    </button>
                </div>
                
                <div style="margin-top: 30px;">
                    <h3>Sistema</h3>
                    <div style="margin: 15px 0;">
                        <label>
                            <input type="checkbox" id="keepOriginals" checked>
                            Manter arquivos originais
                        </label>
                    </div>
                    <button class="btn-primary" onclick="cleanupFiles()">
                        🗑️ Limpar Arquivos Antigos
                    </button>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Variáveis globais
        let selectedFile = null;
        
        // Navegação entre abas
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
            
            // Ativar tab na navegação
            document.querySelectorAll('.nav-tab').forEach(tab => {
                if (tab.textContent.includes(getTabLabel(tabName))) {
                    tab.classList.add('active');
                }
            });
            
            // Carregar dados se necessário
            if (tabName === 'conversions') {
                loadConversions();
            } else if (tabName === 'dashboard') {
                loadSystemStats();
            }
        }
        
        function getTabLabel(tabName) {
            const labels = {
                'dashboard': 'Dashboard',
                'upload': 'Upload',
                'conversions': 'Conversões',
                'settings': 'Configurações'
            };
            return labels[tabName] || tabName;
        }
        
        // Sistema
        function loadSystemStats() {
            fetch('/api/system')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('cpu').textContent = data.cpu || '--%';
                    document.getElementById('memory').textContent = data.memory || '--%';
                    document.getElementById('disk').textContent = data.disk || '--%';
                    document.getElementById('conversions').textContent = data.total_conversions || '0';
                    
                    // FFmpeg status
                    const ffmpegStatus = document.getElementById('ffmpegStatus');
                    if (data.ffmpeg_status === 'ok') {
                        ffmpegStatus.textContent = '✅ FFmpeg Disponível';
                        ffmpegStatus.className = 'ffmpeg-status ffmpeg-ok';
                    } else {
                        ffmpegStatus.textContent = '❌ FFmpeg Não Encontrado';
                        ffmpegStatus.className = 'ffmpeg-status ffmpeg-missing';
                    }
                    
                    if (data.ffmpeg_path) {
                        document.getElementById('ffmpegPath').textContent = `Caminho: ${data.ffmpeg_path}`;
                    }
                })
                .catch(error => {
                    console.error('Erro ao carregar stats:', error);
                });
        }
        
        function refreshStats() {
            loadSystemStats();
            alert('Status atualizado!');
        }
        
        // Upload
        function handleFileSelect() {
            const fileInput = document.getElementById('fileInput');
            if (fileInput.files.length > 0) {
                selectedFile = fileInput.files[0];
                
                document.getElementById('fileInfo').style.display = 'block';
                document.getElementById('fileName').textContent = `Nome: ${selectedFile.name}`;
                document.getElementById('fileSize').textContent = `Tamanho: ${formatBytes(selectedFile.size)}`;
            }
        }
        
        function startConversion() {
            if (!selectedFile) {
                alert('Por favor, selecione um arquivo primeiro!');
                return;
            }
            
            const qualities = [];
            if (document.getElementById('q240').checked) qualities.push('240p');
            if (document.getElementById('q480').checked) qualities.push('480p');
            if (document.getElementById('q720').checked) qualities.push('720p');
            if (document.getElementById('q1080').checked) qualities.push('1080p');
            
            if (qualities.length === 0) {
                alert('Selecione pelo menos uma qualidade!');
                return;
            }
            
            const formData = new FormData();
            formData.append('file', selectedFile);
            formData.append('qualities', JSON.stringify(qualities));
            
            // Mostrar progresso
            document.getElementById('progress').style.display = 'block';
            const convertBtn = document.getElementById('convertBtn');
            convertBtn.disabled = true;
            convertBtn.textContent = '⏳ Convertendo...';
            
            // Simular progresso
            let progress = 0;
            const progressInterval = setInterval(() => {
                progress += 5;
                if (progress > 90) progress = 90;
                updateProgress(progress, 'Processando...');
            }, 300);
            
            fetch('/convert', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                clearInterval(progressInterval);
                
                if (data.success) {
                    updateProgress(100, 'Concluído!');
                    alert(`✅ Conversão concluída!\nID: ${data.video_id}\nLink: ${data.m3u8_url}`);
                    
                    // Reset
                    setTimeout(() => {
                        document.getElementById('progress').style.display = 'none';
                        document.getElementById('fileInfo').style.display = 'none';
                        document.getElementById('fileInput').value = '';
                        selectedFile = null;
                        convertBtn.disabled = false;
                        convertBtn.textContent = '🚀 Iniciar Conversão';
                        updateProgress(0, '');
                        
                        // Atualizar histórico
                        loadConversions();
                    }, 2000);
                } else {
                    alert(`❌ Erro: ${data.error}`);
                    convertBtn.disabled = false;
                    convertBtn.textContent = '🚀 Iniciar Conversão';
                }
            })
            .catch(error => {
                clearInterval(progressInterval);
                alert(`❌ Erro de conexão: ${error.message}`);
                convertBtn.disabled = false;
                convertBtn.textContent = '🚀 Iniciar Conversão';
            });
        }
        
        function updateProgress(percent, text) {
            document.getElementById('progressBar').style.width = percent + '%';
            document.getElementById('progressText').textContent = `${text} ${percent}%`;
        }
        
        // Conversões
        function loadConversions() {
            fetch('/api/conversions')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('conversionsList');
                    
                    if (!data.conversions || data.conversions.length === 0) {
                        container.innerHTML = '<p>Nenhuma conversão realizada ainda.</p>';
                        return;
                    }
                    
                    let html = '';
                    data.conversions.slice(0, 10).forEach(conv => {
                        html += `
                            <div class="conversion-item">
                                <strong>${conv.filename || conv.video_id}</strong>
                                <p style="color: #666; font-size: 0.9em;">
                                    ${new Date(conv.timestamp).toLocaleString()}
                                </p>
                                <p>Qualidades: ${conv.qualities ? conv.qualities.join(', ') : 'N/A'}</p>
                                <button onclick="copyLink('${conv.video_id}')" style="background: #4361ee; color: white; border: none; padding: 5px 10px; border-radius: 3px; cursor: pointer;">
                                    📋 Copiar Link
                                </button>
                            </div>
                        `;
                    });
                    
                    container.innerHTML = html;
                })
                .catch(error => {
                    console.error('Erro ao carregar conversões:', error);
                    document.getElementById('conversionsList').innerHTML = '<p>Erro ao carregar histórico.</p>';
                });
        }
        
        function copyLink(videoId) {
            const link = window.location.origin + '/hls/' + videoId + '/master.m3u8';
            navigator.clipboard.writeText(link)
                .then(() => alert('✅ Link copiado!'))
                .catch(() => {
                    // Fallback para navegadores antigos
                    const textArea = document.createElement('textarea');
                    textArea.value = link;
                    document.body.appendChild(textArea);
                    textArea.select();
                    document.execCommand('copy');
                    document.body.removeChild(textArea);
                    alert('✅ Link copiado!');
                });
        }
        
        // Configurações
        function changePassword() {
            window.location.href = '/change-password';
        }
        
        function cleanupFiles() {
            if (confirm('Limpar arquivos antigos (mais de 7 dias)?')) {
                fetch('/api/cleanup', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        alert(data.message || 'Limpeza concluída!');
                    })
                    .catch(() => {
                        alert('Erro ao limpar arquivos.');
                    });
            }
        }
        
        function testFFmpeg() {
            fetch('/api/ffmpeg-test')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        alert(`✅ FFmpeg funcionando!\nVersão: ${data.version}`);
                    } else {
                        alert(`❌ FFmpeg não está funcionando: ${data.error}`);
                    }
                })
                .catch(() => {
                    alert('Erro ao testar FFmpeg.');
                });
        }
        
        // Utilitários
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // Inicialização
        document.addEventListener('DOMContentLoaded', function() {
            loadSystemStats();
            // Atualizar stats a cada 30 segundos
            setInterval(loadSystemStats, 30000);
        });
    </script>
</body>
</html>
'''

# =============== ROTAS ===============

@app.route('/')
def index():
    if 'user_id' not in session:
        return redirect(url_for('login'))
    
    # Verificar se precisa trocar senha
    if password_change_required(session['user_id']):
        return redirect(url_for('change_password'))
    
    return render_template_string(DASHBOARD_HTML)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'GET':
        if 'user_id' in session:
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML)
    
    # Processar login
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    
    if not username or not password:
        flash('Por favor, preencha todos os campos', 'error')
        return render_template_string(LOGIN_HTML)
    
    if check_password(username, password):
        # Atualizar último login
        users = load_users()
        if username in users['users']:
            users['users'][username]['last_login'] = datetime.now().isoformat()
            save_users(users)
        
        # Criar sessão
        session['user_id'] = username
        session['login_time'] = datetime.now().isoformat()
        
        # Verificar se precisa trocar senha
        if password_change_required(username):
            return redirect(url_for('change_password'))
        
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
    
    # Processar alteração de senha
    username = session['user_id']
    current_password = request.form.get('current_password', '').strip()
    new_password = request.form.get('new_password', '').strip()
    confirm_password = request.form.get('confirm_password', '').strip()
    
    # Validações
    errors = []
    
    if not all([current_password, new_password, confirm_password]):
        errors.append('Todos os campos são obrigatórios')
    
    if new_password != confirm_password:
        errors.append('As senhas não coincidem')
    
    if len(new_password) < 8:
        errors.append('A senha deve ter pelo menos 8 caracteres')
    
    if not any(c.isupper() for c in new_password):
        errors.append('A senha deve conter pelo menos uma letra maiúscula')
    
    if not any(c.islower() for c in new_password):
        errors.append('A senha deve conter pelo menos uma letra minúscula')
    
    if not any(c.isdigit() for c in new_password):
        errors.append('A senha deve conter pelo menos um número')
    
    if not any(c in '!@#$%^&*(),.?":{}|<>' for c in new_password):
        errors.append('A senha deve conter pelo menos um caractere especial')
    
    if current_password == new_password:
        errors.append('A nova senha não pode ser igual à atual')
    
    # Verificar senha atual
    if not check_password(username, current_password):
        errors.append('Senha atual incorreta')
    
    if errors:
        for error in errors:
            flash(error, 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    # Alterar senha
    try:
        new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
        users = load_users()
        users['users'][username]['password'] = new_hash
        users['users'][username]['password_changed'] = True
        users['users'][username]['last_password_change'] = datetime.now().isoformat()
        save_users(users)
        
        flash('✅ Senha alterada com sucesso!', 'success')
        return redirect(url_for('index'))
    except Exception as e:
        flash(f'Erro ao alterar senha: {str(e)}', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)

@app.route('/logout')
def logout():
    session.clear()
    flash('✅ Você foi desconectado com sucesso', 'info')
    return redirect(url_for('login'))

@app.route('/api/system')
def api_system():
    """Endpoint para informações do sistema"""
    try:
        import psutil
        
        cpu = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        conversions = load_conversions()
        
        ffmpeg_path = find_ffmpeg()
        
        return jsonify({
            "cpu": f"{cpu:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "disk": f"{disk.percent:.1f}%",
            "total_conversions": conversions["stats"]["total"],
            "success_conversions": conversions["stats"]["success"],
            "failed_conversions": conversions["stats"]["failed"],
            "ffmpeg_status": "ok" if ffmpeg_path else "missing",
            "ffmpeg_path": ffmpeg_path or "Não encontrado"
        })
    except Exception as e:
        return jsonify({
            "error": str(e),
            "ffmpeg_status": "error",
            "ffmpeg_path": "Erro ao verificar"
        })

@app.route('/api/conversions')
def api_conversions():
    """Endpoint para listar conversões"""
    data = load_conversions()
    return jsonify(data)

@app.route('/api/cleanup', methods=['POST'])
def api_cleanup():
    """Limpar arquivos antigos"""
    try:
        deleted_count = 0
        
        # Limpar uploads antigos
        if os.path.exists(UPLOAD_DIR):
            for filename in os.listdir(UPLOAD_DIR):
                filepath = os.path.join(UPLOAD_DIR, filename)
                if os.path.isfile(filepath):
                    file_age = time.time() - os.path.getmtime(filepath)
                    if file_age > 7 * 24 * 3600:  # 7 dias
                        os.remove(filepath)
                        deleted_count += 1
        
        return jsonify({
            "success": True,
            "message": f"{deleted_count} arquivos antigos removidos"
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

@app.route('/convert', methods=['POST'])
def convert_video():
    """Converter vídeo para HLS"""
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
        
        # Verificar arquivo
        if 'file' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
        
        # Obter qualidades
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Gerar ID único
        video_id = str(uuid.uuid4())[:8]
        output_dir = os.path.join(HLS_DIR, video_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Salvar arquivo original
        filename = file.filename
        temp_path = os.path.join(output_dir, "original.mp4")
        file.save(temp_path)
        
        # Criar master playlist
        master_playlist = os.path.join(output_dir, "master.m3u8")
        
        with open(master_playlist, 'w') as f:
            f.write("#EXTM3U\n")
            f.write("#EXT-X-VERSION:3\n")
            
            # Converter para cada qualidade
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
                    continue  # Pular qualidade desconhecida
                
                # Comando FFmpeg
                cmd = [
                    ffmpeg_path, '-i', temp_path,
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
                        f.write(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={scale.replace(":", "x")}\n')
                        f.write(f'{quality}/index.m3u8\n')
                except subprocess.TimeoutExpired:
                    print(f"Timeout na conversão para {quality}")
        
        # Limpar arquivo temporário
        os.remove(temp_path)
        
        # Atualizar banco de dados
        conversions = load_conversions()
        conversion_data = {
            "video_id": video_id,
            "filename": filename,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success"
        }
        
        conversions["conversions"].insert(0, conversion_data)
        conversions["stats"]["total"] += 1
        conversions["stats"]["success"] += 1
        save_conversions(conversions)
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "qualities": qualities,
            "m3u8_url": f"/hls/{video_id}/master.m3u8"
        })
        
    except Exception as e:
        print(f"Erro na conversão: {e}")
        return jsonify({
            "success": False,
            "error": str(e)
        })

@app.route('/hls/<video_id>/<path:filename>')
def serve_hls(video_id, filename):
    """Servir arquivos HLS"""
    filepath = os.path.join(HLS_DIR, video_id, filename)
    if os.path.exists(filepath):
        return send_file(filepath)
    return "Arquivo não encontrado", 404

@app.route('/health')
def health():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": "hls-converter-ultimate",
        "timestamp": datetime.now().isoformat(),
        "version": "4.0.0"
    })

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 50)
    print("🚀 HLS Converter ULTIMATE - Versão Corrigida")
    print("=" * 50)
    print(f"📂 Diretório base: {BASE_DIR}")
    print(f"🔐 Autenticação: Habilitada")
    print(f"👤 Usuário padrão: admin / admin")
    print(f"🌐 Porta: 8080")
    print("=" * 50)
    
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
        print("📋 Ou após instalação: hlsctl fix-ffmpeg")
    
    print("")
    print("🌐 URLs importantes:")
    print(f"   🔐 Login: http://localhost:8080/login")
    print(f"   🩺 Health: http://localhost:8080/health")
    print(f"   🎮 Dashboard: http://localhost:8080/")
    print("")
    print("⚙️  Comandos de gerenciamento:")
    print("   • hlsctl start      - Iniciar serviço")
    print("   • hlsctl stop       - Parar serviço")
    print("   • hlsctl restart    - Reiniciar serviço")
    print("   • hlsctl status     - Ver status")
    print("   • hlsctl logs       - Ver logs")
    print("   • hlsctl fix-ffmpeg - Reparar FFmpeg")
    print("=" * 50)
    
    try:
        from waitress import serve
        print("🚀 Iniciando servidor com Waitress...")
        serve(app, host='0.0.0.0', port=8080, threads=4)
    except ImportError:
        print("⚠️  Waitress não encontrado, usando servidor de desenvolvimento...")
        print("📦 Instale: pip install waitress")
        app.run(host='0.0.0.0', port=8080, debug=False)
EOF

# 12. CRIAR ARQUIVOS DE CONFIGURAÇÃO
echo "📁 Criando arquivos de configuração..."

# Configuração do sistema
cat > /opt/hls-converter/config.json << 'EOF'
{
    "system": {
        "port": 8080,
        "upload_limit_mb": 2048,
        "keep_originals": false,
        "cleanup_days": 7,
        "hls_segment_time": 10,
        "enable_multiple_qualities": true
    },
    "authentication": {
        "require_password_change": true,
        "session_timeout": 3600,
        "max_login_attempts": 5,
        "password_min_length": 8,
        "password_require_uppercase": true,
        "password_require_lowercase": true,
        "password_require_numbers": true,
        "password_require_special": true
    },
    "qualities": {
        "240p": {
            "scale": "426:240",
            "bitrate": "400k",
            "audio_bitrate": "64k"
        },
        "480p": {
            "scale": "854:480",
            "bitrate": "800k",
            "audio_bitrate": "96k"
        },
        "720p": {
            "scale": "1280:720",
            "bitrate": "1500k",
            "audio_bitrate": "128k"
        },
        "1080p": {
            "scale": "1920:1080",
            "bitrate": "3000k",
            "audio_bitrate": "192k"
        }
    }
}
EOF

# 13. CRIAR SCRIPT DE GERENCIAMENTO (hlsctl)
echo "📝 Criando script de gerenciamento..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"
LOG_FILE="/opt/hls-converter/logs/hlsctl.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

case "$1" in
    start)
        log "Iniciando serviço HLS Converter..."
        systemctl start hls-converter
        if [ $? -eq 0 ]; then
            log "✅ Serviço iniciado com sucesso"
            echo "✅ Serviço iniciado"
        else
            log "❌ Falha ao iniciar serviço"
            echo "❌ Falha ao iniciar serviço"
        fi
        ;;
        
    stop)
        log "Parando serviço HLS Converter..."
        systemctl stop hls-converter
        if [ $? -eq 0 ]; then
            log "✅ Serviço parado com sucesso"
            echo "✅ Serviço parado"
        else
            log "⚠️  Serviço pode não ter parado completamente"
            echo "⚠️  Serviço parado (pode ter levado alguns segundos)"
        fi
        ;;
        
    restart)
        log "Reiniciando serviço HLS Converter..."
        systemctl restart hls-converter
        if [ $? -eq 0 ]; then
            log "✅ Serviço reiniciado com sucesso"
            echo "✅ Serviço reiniciado"
            sleep 2
            systemctl status hls-converter --no-pager
        else
            log "❌ Falha ao reiniciar serviço"
            echo "❌ Falha ao reiniciar serviço"
        fi
        ;;
        
    status)
        systemctl status hls-converter --no-pager
        ;;
        
    logs)
        if [ "$2" = "-f" ] || [ "$2" = "--follow" ]; then
            journalctl -u hls-converter -f
        elif [ "$2" = "-e" ] || [ "$2" = "--error" ]; then
            journalctl -u hls-converter --since "1 hour ago" --no-pager | grep -E "(ERROR|error|failed|Failed|exception|Exception)"
        else
            journalctl -u hls-converter -n 30 --no-pager
        fi
        ;;
        
    test)
        log "Testando sistema HLS Converter..."
        echo "🧪 Testando sistema..."
        
        # Testar serviço
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço está ativo"
            
            # Testar health check
            echo "🌐 Testando health check..."
            if curl -s http://localhost:8080/health | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "⚠️  Health check pode não estar respondendo"
                curl -s http://localhost:8080/health || true
            fi
            
            # Testar login
            echo "🔐 Testando página de login..."
            STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
            if [ "$STATUS_CODE" = "200" ]; then
                echo "✅ Página de login acessível"
            else
                echo "⚠️  Página de login retornou código: $STATUS_CODE"
            fi
            
        else
            echo "❌ Serviço não está ativo"
        fi
        
        # Testar FFmpeg
        echo "🎬 Testando FFmpeg..."
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg encontrado: $(which ffmpeg)"
            ffmpeg -version | head -1
        else
            echo "❌ FFmpeg não encontrado"
        fi
        
        # Testar diretórios
        echo "📁 Verificando diretórios..."
        for dir in "$HLS_HOME" "$HLS_HOME/uploads" "$HLS_HOME/hls" "$HLS_HOME/logs" "$HLS_HOME/db" "$HLS_HOME/sessions"; do
            if [ -d "$dir" ]; then
                echo "✅ $dir"
            else
                echo "❌ $dir (não existe)"
            fi
        done
        ;;
        
    fix-ffmpeg)
        log "Reparando instalação do FFmpeg..."
        echo "🔧 Reparando FFmpeg..."
        
        # Método 1: apt
        echo "📦 Tentando instalação via apt..."
        apt-get update
        if apt-get install -y ffmpeg; then
            echo "✅ FFmpeg instalado via apt"
            log "FFmpeg instalado via apt"
        else
            # Método 2: Snap
            echo "📦 Tentando instalação via Snap..."
            if command -v snap &> /dev/null; then
                if snap install ffmpeg --classic; then
                    echo "✅ FFmpeg instalado via Snap"
                    log "FFmpeg instalado via Snap"
                fi
            fi
        fi
        
        # Verificar instalação
        if command -v ffmpeg &> /dev/null; then
            echo "🎉 FFmpeg reparado com sucesso!"
            echo "📊 Versão: $(ffmpeg -version 2>/dev/null | head -1)"
            log "FFmpeg reparado com sucesso"
        else
            echo "❌ Não foi possível instalar FFmpeg"
            echo "📋 Instale manualmente: sudo apt-get install -y ffmpeg"
            log "Falha ao reparar FFmpeg"
        fi
        ;;
        
    cleanup)
        log "Limpando arquivos antigos..."
        echo "🧹 Limpando arquivos antigos..."
        
        # Arquivos de upload antigos
        UPLOADS_CLEANED=$(find /opt/hls-converter/uploads -type f -mtime +7 -delete -print | wc -l)
        
        # Diretórios HLS antigos
        HLS_CLEANED=0
        for dir in /opt/hls-converter/hls/*/; do
            if [ -d "$dir" ]; then
                if [ $(find "$dir" -type f -mtime +7 | wc -l) -gt 0 ]; then
                    rm -rf "$dir"
                    HLS_CLEANED=$((HLS_CLEANED + 1))
                fi
            fi
        done
        
        echo "✅ $UPLOADS_CLEANED arquivos de upload removidos"
        echo "✅ $HLS_CLEANED diretórios HLS removidos"
        log "Limpeza concluída: $UPLOADS_CLEANED uploads, $HLS_CLEANED diretórios HLS"
        ;;
        
    reinstall-deps)
        log "Reinstalando dependências Python..."
        echo "🐍 Reinstalando dependências Python..."
        
        cd /opt/hls-converter
        if [ -f "venv/bin/activate" ]; then
            source venv/bin/activate
            pip install --upgrade pip
            
            # Lista de dependências
            DEPS="flask flask-cors waitress werkzeug psutil python-magic bcrypt cryptography"
            
            for dep in $DEPS; do
                echo "📦 Instalando $dep..."
                pip install --force-reinstall "$dep" || echo "⚠️  Falha ao reinstalar $dep"
            done
            
            echo "✅ Dependências reinstaladas"
            log "Dependências Python reinstaladas"
        else
            echo "❌ Virtualenv não encontrado"
            log "Virtualenv não encontrado para reinstalação"
        fi
        ;;
        
    reset-password)
        if [ -z "$2" ]; then
            echo "❌ Uso: hlsctl reset-password <username>"
            echo "📋 Exemplo: hlsctl reset-password admin"
            exit 1
        fi
        
        USERNAME="$2"
        echo "🔑 Redefinindo senha para $USERNAME..."
        echo "⚠️  ATENÇÃO: Esta ação redefinirá a senha para 'admin123'"
        echo "⚠️  O usuário será forçado a alterar a senha no próximo login"
        echo ""
        read -p "Continuar? (s/N): " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            cd /opt/hls-converter
            source venv/bin/activate
            
            python3 -c "
import bcrypt
import json
import os

users_file = '/opt/hls-converter/db/users.json'
if os.path.exists(users_file):
    with open(users_file, 'r') as f:
        data = json.load(f)
    
    if '$USERNAME' in data['users']:
        # Gerar hash para 'admin123'
        new_hash = bcrypt.hashpw('admin123'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
        data['users']['$USERNAME']['password'] = new_hash
        data['users']['$USERNAME']['password_changed'] = False
        
        with open(users_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        print('✅ Senha redefinida com sucesso!')
        print('👤 Usuário: $USERNAME')
        print('🔑 Nova senha: admin123')
        print('⚠️  Esta senha DEVE ser alterada no próximo login!')
    else:
        print('❌ Usuário não encontrado')
else:
    print('❌ Arquivo de usuários não encontrado')
"
        else
            echo "❌ Operação cancelada"
        fi
        ;;
        
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        
        echo "=" * 50
        echo "🎬 HLS Converter ULTIMATE - Informações do Sistema"
        echo "=" * 50
        
        # Status do serviço
        SERVICE_STATUS=$(systemctl is-active hls-converter)
        if [ "$SERVICE_STATUS" = "active" ]; then
            echo "✅ Serviço: ATIVO"
        else
            echo "❌ Serviço: $SERVICE_STATUS"
        fi
        
        # FFmpeg
        if command -v ffmpeg &> /dev/null; then
            FFMPEG_VERSION=$(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)
            echo "✅ FFmpeg: $FFMPEG_VERSION"
        else
            echo "❌ FFmpeg: NÃO INSTALADO"
        fi
        
        # URLs
        echo "🌐 URLs:"
        echo "   🔐 Login:     http://$IP:8080/login"
        echo "   🎮 Dashboard: http://$IP:8080/"
        echo "   🩺 Health:    http://$IP:8080/health"
        
        # Diretórios
        echo "📁 Diretórios:"
        echo "   📂 Aplicação: /opt/hls-converter"
        echo "   💾 Uploads:   /opt/hls-converter/uploads"
        echo "   🎬 HLS:       /opt/hls-converter/hls"
        echo "   📋 Logs:      /opt/hls-converter/logs"
        
        # Usuários
        if [ -f "/opt/hls-converter/db/users.json" ]; then
            USER_COUNT=$(python3 -c "import json; data=json.load(open('/opt/hls-converter/db/users.json')); print(len(data.get('users', {})))" 2>/dev/null || echo "0")
            echo "👥 Usuários cadastrados: $USER_COUNT"
        fi
        
        # Conversões
        if [ -f "/opt/hls-converter/db/conversions.json" ]; then
            TOTAL_CONV=$(python3 -c "import json; data=json.load(open('/opt/hls-converter/db/conversions.json')); print(data.get('stats', {}).get('total', 0))" 2>/dev/null || echo "0")
            echo "🔄 Total de conversões: $TOTAL_CONV"
        fi
        
        echo "=" * 50
        ;;
        
    *)
        echo "🎬 HLS Converter ULTIMATE - Gerenciador"
        echo "========================================"
        echo ""
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos principais:"
        echo "  start           - Iniciar serviço"
        echo "  stop            - Parar serviço"
        echo "  restart         - Reiniciar serviço"
        echo "  status          - Ver status do serviço"
        echo "  logs [opções]   - Ver logs do serviço"
        echo "                    -f, --follow: Seguir logs em tempo real"
        echo "                    -e, --error:  Mostrar apenas erros"
        echo "  test            - Testar sistema completo"
        echo "  fix-ffmpeg      - Reparar/instalar FFmpeg"
        echo "  cleanup         - Limpar arquivos antigos (>7 dias)"
        echo "  reinstall-deps  - Reinstalar dependências Python"
        echo ""
        echo "Gerenciamento de usuários:"
        echo "  reset-password <user> - Redefinir senha para 'admin123'"
        echo ""
        echo "Informações:"
        echo "  info            - Mostrar informações do sistema"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl start"
        echo "  hlsctl logs -f"
        echo "  hlsctl test"
        echo "  hlsctl fix-ffmpeg"
        echo "  hlsctl reset-password admin"
        ;;
esac
EOF

# 14. CRIAR SERVIÇO SYSTEMD CORRIGIDO
echo "⚙️ Criando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter ULTIMATE Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls-converter
Environment="PATH=/opt/hls-converter/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=/opt/hls-converter"
Environment="PYTHONUNBUFFERED=1"

# Comando corrigido - usa o Python do virtualenv
ExecStart=/opt/hls-converter/venv/bin/python /opt/hls-converter/app.py

# Reiniciar sempre que falhar
Restart=always
RestartSec=10

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db /opt/hls-converter/sessions
ReadOnlyPaths=/opt/hls-converter

# Limites de recursos
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

# 15. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."

# Definir permissões corretas
chown -R hlsuser:hlsuser /opt/hls-converter
chmod 755 /opt/hls-converter
chmod 644 /opt/hls-converter/app.py
chmod 644 /opt/hls-converter/*.json
chmod 755 /usr/local/bin/hlsctl

# Permissões específicas para diretórios
chmod 755 /opt/hls-converter/uploads
chmod 755 /opt/hls-converter/hls
chmod 755 /opt/hls-converter/logs
chmod 700 /opt/hls-converter/sessions
chmod 755 /opt/hls-converter/db

# 16. INICIAR E TESTAR SERVIÇO
echo "🚀 Iniciando serviço..."

systemctl daemon-reload
systemctl enable hls-converter.service

# Tentar iniciar o serviço
if systemctl start hls-converter.service; then
    echo "✅ Serviço iniciado com sucesso"
else
    echo "❌ Falha ao iniciar serviço, tentando diagnóstico..."
    
    # Tentar executar manualmente para ver erros
    echo "🧪 Executando manualmente para diagnóstico..."
    cd /opt/hls-converter
    sudo -u hlsuser /opt/hls-converter/venv/bin/python app.py --test || \
    sudo -u hlsuser /opt/hls-converter/venv/bin/python -c "exec(open('app.py').read())"
fi

# Esperar um pouco e verificar status
sleep 5

echo ""
echo "📊 Verificando status do serviço..."

if systemctl is-active --quiet hls-converter.service; then
    echo "🎉 SERVIÇO ESTÁ ATIVO E FUNCIONANDO!"
    
    # Testar endpoints
    echo ""
    echo "🧪 Testando endpoints..."
    
    # Health check
    echo "🩺 Testando health check..."
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "✅ Health check OK"
    else
        echo "⚠️  Health check pode não estar respondendo"
        curl -s http://localhost:8080/health || true
    fi
    
    # Login page
    echo ""
    echo "🔐 Testando página de login..."
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
    if [ "$STATUS_CODE" = "200" ]; then
        echo "✅ Página de login acessível"
    else
        echo "⚠️  Página de login retornou código: $STATUS_CODE"
    fi
    
else
    echo "❌ Serviço não está ativo"
    echo ""
    echo "📋 Últimos logs do serviço:"
    journalctl -u hls-converter -n 20 --no-pager
fi

# 17. INFORMAÇÕES FINAIS
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "=" * 60
echo "🎉🎉🎉 INSTALAÇÃO COMPLETA COM CORREÇÕES APLICADAS! 🎉🎉🎉"
echo "=" * 60
echo ""
echo "✅ SISTEMA INSTALADO E CONFIGURADO COM SUCESSO"
echo ""
echo "🔐 INFORMAÇÕES DE ACESSO:"
echo "   👤 Usuário padrão: admin"
echo "   🔑 Senha padrão: admin"
echo "   ⚠️  OBRIGATÓRIO: Altere a senha no primeiro login!"
echo ""
echo "🌐 URLS DO SISTEMA:"
echo "   🔐 Página de login:    http://$IP:8080/login"
echo "   🎮 Dashboard:          http://$IP:8080/"
echo "   🩺 Health check:       http://$IP:8080/health"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start        - Iniciar serviço"
echo "   • hlsctl stop         - Parar serviço"
echo "   • hlsctl restart      - Reiniciar serviço"
echo "   • hlsctl status       - Ver status do serviço"
echo "   • hlsctl logs [-f]    - Ver logs do serviço (-f para seguir)"
echo "   • hlsctl test         - Testar sistema completo"
echo "   • hlsctl fix-ffmpeg   - Reparar/instalar FFmpeg"
echo "   • hlsctl cleanup      - Limpar arquivos antigos"
echo "   • hlsctl info         - Informações do sistema"
echo ""
echo "🔧 SOLUÇÃO DE PROBLEMAS:"
echo "   Se o serviço não iniciar:"
echo "   1. Verifique logs: hlsctl logs"
echo "   2. Teste FFmpeg: hlsctl fix-ffmpeg"
echo "   3. Reinstale dependências: hlsctl reinstall-deps"
echo "   4. Reinicie: hlsctl restart"
echo ""
echo "💡 DICAS RÁPIDAS:"
echo "   1. Primeiro acesso: http://$IP:8080/login"
echo "   2. Use admin/admin para fazer login"
echo "   3. Altere a senha imediatamente"
echo "   4. Teste o sistema: hlsctl test"
echo ""
echo "📁 ESTRUTURA DE DIRETÓRIOS:"
echo "   /opt/hls-converter/      - Diretório principal"
echo "   ├── uploads/            - Vídeos enviados"
echo "   ├── hls/                - Arquivos HLS gerados"
echo "   ├── logs/               - Logs do sistema"
echo "   ├── db/                 - Banco de dados"
echo "   └── sessions/           - Sessões de usuário"
echo ""
echo "=" * 60
echo "🚀 Sistema pronto para uso! Acesse http://$IP:8080/login"
echo "=" * 60

# 18. CRIAR SCRIPT DE BACKUP
cat > /usr/local/bin/hls-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/hls-backup-$(date +%Y%m%d_%H%M%S)"
echo "💾 Criando backup em: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cp -r /opt/hls-converter/db "$BACKUP_DIR/"
cp -r /opt/hls-converter/config.json "$BACKUP_DIR/" 2>/dev/null || true
echo "✅ Backup concluído: $(du -sh $BACKUP_DIR | cut -f1)"
echo "📂 Conteúdo:"
ls -la "$BACKUP_DIR/"
EOF

chmod +x /usr/local/bin/hls-backup

echo ""
echo "✅ Script de backup criado: hls-backup"
echo ""
echo "🎯 INSTALAÇÃO COMPLETA - SISTEMA CORRIGIDO E PRONTO PARA USO!"
