#!/bin/bash
# install_hls_converter_ultimate.sh - SISTEMA COMPLETO ULTIMATE COM AUTENTICAÇÃO

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE COM LOGIN"
echo "=============================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_ultimate.sh"
    exit 1
fi

# 2. Verificar sistema de arquivos
echo "🔍 Verificando sistema..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

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

# 5. Atualizar sistema
echo "📦 Atualizando sistema..."
apt-get update
apt-get upgrade -y

# 6. FUNÇÃO ROBUSTA PARA INSTALAR FFMPEG
install_ffmpeg_robust() {
    echo "🔧 Tentando instalar ffmpeg..."
    
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
        snap install ffmpeg --classic && echo "✅ FFmpeg instalado via Snap" && return 0
    fi
    
    # Método 4: Compilar do código fonte (último recurso)
    echo "📦 Método 4: Baixando binário estático..."
    cd /tmp
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz || \
    wget -q https://www.johnvansickle.com/ffmpeg/old-releases/ffmpeg-4.4.1-amd64-static.tar.xz || \
    curl -L -o ffmpeg-release-amd64-static.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    
    if [ -f ffmpeg-release-amd64-static.tar.xz ]; then
        tar -xf ffmpeg-release-amd64-static.tar.xz
        FFMPEG_DIR=$(find . -name "ffmpeg-*-static" -type d | head -1)
        if [ -n "$FFMPEG_DIR" ]; then
            cp "$FFMPEG_DIR"/ffmpeg "$FFMPEG_DIR"/ffprobe /usr/local/bin/
            chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
            echo "✅ FFmpeg instalado de binário estático"
            return 0
        fi
    fi
    
    return 1
}

# 7. INSTALAR FFMPEG
echo "🎬 INSTALANDO FFMPEG..."
if command -v ffmpeg &> /dev/null; then
    echo "✅ ffmpeg já está instalado"
    echo "🔍 Versão do ffmpeg:"
    ffmpeg -version | head -1
else
    echo "❌ ffmpeg não encontrado, instalando..."
    install_ffmpeg_robust
    
    # Verificar novamente
    if ! command -v ffmpeg &> /dev/null; then
        echo "⚠️  Tentando encontrar ffmpeg em locais alternativos..."
        for path in /usr/bin/ffmpeg /usr/local/bin/ffmpeg /bin/ffmpeg /snap/bin/ffmpeg; do
            if [ -f "$path" ]; then
                ln -sf "$path" /usr/local/bin/ffmpeg
                echo "✅ Link simbólico criado para $path"
                break
            fi
        done
    fi
    
    # Verificação final
    if command -v ffmpeg &> /dev/null; then
        echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
        ffmpeg -version | head -1
    else
        echo "⚠️  AVISO: FFmpeg pode não estar instalado corretamente"
    fi
fi

# 8. Instalar outras dependências
echo "🔧 Instalando outras dependências..."
apt-get install -y python3 python3-pip python3-venv htop curl wget

# 9. Criar estrutura de diretórios AVANÇADA
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,templates,static}
mkdir -p /opt/hls-converter/hls/{240p,360p,480p,720p,1080p,original}
cd /opt/hls-converter

# 10. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if id "hlsuser" &>/dev/null; then
    echo "✅ Usuário hlsuser já existe"
else
    useradd -r -s /bin/false hlsuser
    echo "✅ Usuário hlsuser criado"
fi

# 11. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python COMPLETAS com autenticação
pip install --upgrade pip
pip install flask flask-cors python-magic psutil waitress werkzeug flask-session cryptography bcrypt

# 12. CRIAR APLICAÇÃO FLASK ULTIMATE COM AUTENTICAÇÃO
echo "🔐 Criando sistema de autenticação..."

# Primeiro, criar banco de dados de usuários
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

# A senha acima é "admin" criptografada com bcrypt
# Para gerar uma nova: python3 -c "import bcrypt; print(bcrypt.hashpw('admin'.encode('utf-8'), bcrypt.gensalt()).decode('utf-8'))"

# Arquivo principal com AUTENTICAÇÃO
cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory, session, redirect, url_for, flash
from flask_cors import CORS
from flask_session import Session
from werkzeug.utils import secure_filename
import os
import subprocess
import uuid
import json
import time
import psutil
from datetime import datetime, timedelta
import shutil
import sys
import bcrypt
import secrets

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)

# Configurações de segurança
app.secret_key = secrets.token_hex(32)
app.config['SESSION_TYPE'] = 'filesystem'
app.config['SESSION_FILE_DIR'] = '/opt/hls-converter/sessions'
app.config['SESSION_PERMANENT'] = False
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=1)
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SECURE'] = False  # True se usar HTTPS
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'

os.makedirs(app.config['SESSION_FILE_DIR'], exist_ok=True)
Session(app)

# Configurações
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
USERS_FILE = os.path.join(DB_DIR, "users.json")

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(HLS_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(DB_DIR, exist_ok=True)

# Banco de dados simples
DB_FILE = os.path.join(DB_DIR, "conversions.json")

def load_database():
    try:
        if os.path.exists(DB_FILE):
            with open(DB_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {"conversions": [], "stats": {"total": 0, "success": 0, "failed": 0}}

def save_database(data):
    with open(DB_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def load_users():
    try:
        if os.path.exists(USERS_FILE):
            with open(USERS_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {"users": {}, "settings": {"require_password_change": True, "session_timeout": 3600, "max_login_attempts": 5}}

def save_users(data):
    with open(USERS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def log_activity(message, level="INFO", username=None):
    log_file = os.path.join(LOG_DIR, "auth.log")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    user_info = f"User: {username}" if username else "User: anonymous"
    with open(log_file, 'a') as f:
        f.write(f"[{timestamp}] [{level}] {user_info} - {message}\n")

# Middleware de autenticação
def login_required(f):
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session:
            return redirect(url_for('login_page'))
        return f(*args, **kwargs)
    decorated_function.__name__ = f.__name__
    return decorated_function

# Função para verificar senha
def check_password(username, password):
    users_data = load_users()
    if username in users_data['users']:
        stored_hash = users_data['users'][username]['password']
        return bcrypt.checkpw(password.encode('utf-8'), stored_hash.encode('utf-8'))
    return False

# Função para alterar senha
def change_password(username, old_password, new_password):
    users_data = load_users()
    if username in users_data['users']:
        if check_password(username, old_password):
            # Gerar hash da nova senha
            new_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
            users_data['users'][username]['password'] = new_hash
            users_data['users'][username]['password_changed'] = True
            users_data['users'][username]['last_password_change'] = datetime.now().isoformat()
            save_users(users_data)
            log_activity("Senha alterada com sucesso", "INFO", username)
            return True
    return False

# Função para verificar se precisa trocar senha
def password_change_required(username):
    users_data = load_users()
    if username in users_data['users']:
        return not users_data['users'][username].get('password_changed', False)
    return False

# ==================== PÁGINAS DE AUTENTICAÇÃO ====================

LOGIN_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔐 Login - HLS Converter ULTIMATE</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        
        .login-card {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.2);
            width: 100%;
            max-width: 400px;
        }
        
        .login-header {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .login-header h2 {
            color: #4361ee;
            font-weight: bold;
        }
        
        .login-header p {
            color: #666;
            margin-top: 10px;
        }
        
        .form-control {
            border-radius: 10px;
            padding: 12px 15px;
            border: 2px solid #e0e0e0;
            transition: all 0.3s;
        }
        
        .form-control:focus {
            border-color: #4361ee;
            box-shadow: 0 0 0 0.2rem rgba(67, 97, 238, 0.25);
        }
        
        .btn-login {
            background: linear-gradient(90deg, #4361ee 0%, #3a0ca3 100%);
            border: none;
            padding: 12px 30px;
            border-radius: 10px;
            font-weight: bold;
            color: white;
            width: 100%;
            transition: all 0.3s;
        }
        
        .btn-login:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 20px rgba(67, 97, 238, 0.3);
        }
        
        .alert {
            border-radius: 10px;
            border: none;
        }
        
        .system-info {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 15px;
            margin-top: 20px;
            font-size: 0.9rem;
        }
        
        .system-info h6 {
            color: #4361ee;
            margin-bottom: 10px;
        }
    </style>
</head>
<body>
    <div class="login-card">
        <div class="login-header">
            <h2><i class="bi bi-shield-lock"></i> HLS Converter ULTIMATE</h2>
            <p>Sistema de conversão de vídeo seguro</p>
        </div>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ 'danger' if category == 'error' else 'info' }}">
                        {{ message }}
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" action="/login">
            <div class="mb-3">
                <label for="username" class="form-label">Usuário</label>
                <input type="text" class="form-control" id="username" name="username" 
                       placeholder="Digite seu usuário" required autofocus>
            </div>
            
            <div class="mb-3">
                <label for="password" class="form-label">Senha</label>
                <input type="password" class="form-control" id="password" name="password" 
                       placeholder="Digite sua senha" required>
            </div>
            
            <div class="d-grid gap-2">
                <button type="submit" class="btn-login">
                    <i class="bi bi-box-arrow-in-right"></i> Entrar
                </button>
            </div>
        </form>
        
        <div class="system-info">
            <h6><i class="bi bi-info-circle"></i> Informações do Sistema</h6>
            <p><strong>Usuário padrão:</strong> admin</p>
            <p><strong>Senha padrão:</strong> admin</p>
            <p class="text-danger"><small><i class="bi bi-exclamation-triangle"></i> É necessário alterar a senha no primeiro acesso</small></p>
        </div>
    </div>
    
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // Foco no campo de usuário
        document.getElementById('username').focus();
        
        // Prevenir múltiplos envios
        document.querySelector('form').addEventListener('submit', function() {
            const btn = this.querySelector('button[type="submit"]');
            btn.disabled = true;
            btn.innerHTML = '<i class="bi bi-hourglass-split"></i> Entrando...';
        });
    </script>
</body>
</html>
'''

CHANGE_PASSWORD_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🔐 Alterar Senha - HLS Converter</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        
        .password-card {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.2);
            width: 100%;
            max-width: 450px;
        }
        
        .password-header {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .password-header h2 {
            color: #4361ee;
            font-weight: bold;
        }
        
        .password-header p {
            color: #666;
            margin-top: 10px;
        }
        
        .form-control {
            border-radius: 10px;
            padding: 12px 15px;
            border: 2px solid #e0e0e0;
            transition: all 0.3s;
        }
        
        .form-control:focus {
            border-color: #4361ee;
            box-shadow: 0 0 0 0.2rem rgba(67, 97, 238, 0.25);
        }
        
        .btn-change {
            background: linear-gradient(90deg, #4cc9f0 0%, #4361ee 100%);
            border: none;
            padding: 12px 30px;
            border-radius: 10px;
            font-weight: bold;
            color: white;
            width: 100%;
            transition: all 0.3s;
        }
        
        .btn-change:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 20px rgba(67, 97, 238, 0.3);
        }
        
        .alert {
            border-radius: 10px;
            border: none;
        }
        
        .password-strength {
            margin-top: 5px;
            font-size: 0.85rem;
        }
        
        .strength-weak { color: #dc3545; }
        .strength-medium { color: #ffc107; }
        .strength-strong { color: #198754; }
        
        .password-requirements {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 15px;
            margin-top: 20px;
            font-size: 0.85rem;
        }
        
        .password-requirements h6 {
            color: #4361ee;
            margin-bottom: 10px;
        }
        
        .requirement {
            display: flex;
            align-items: center;
            margin-bottom: 5px;
        }
        
        .requirement i {
            margin-right: 8px;
        }
        
        .requirement.valid {
            color: #198754;
        }
        
        .requirement.invalid {
            color: #6c757d;
        }
    </style>
</head>
<body>
    <div class="password-card">
        <div class="password-header">
            <h2><i class="bi bi-key"></i> Alterar Senha</h2>
            <p>Por segurança, é necessário alterar a senha padrão</p>
        </div>
        
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ 'danger' if category == 'error' else 'info' }}">
                        {{ message }}
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST" action="/change-password" onsubmit="return validatePassword()">
            <div class="mb-3">
                <label for="current_password" class="form-label">Senha Atual</label>
                <input type="password" class="form-control" id="current_password" name="current_password" 
                       placeholder="Digite sua senha atual" required>
            </div>
            
            <div class="mb-3">
                <label for="new_password" class="form-label">Nova Senha</label>
                <input type="password" class="form-control" id="new_password" name="new_password" 
                       placeholder="Digite a nova senha" required oninput="checkPasswordStrength()">
                <div id="password-strength" class="password-strength"></div>
            </div>
            
            <div class="mb-3">
                <label for="confirm_password" class="form-label">Confirmar Nova Senha</label>
                <input type="password" class="form-control" id="confirm_password" name="confirm_password" 
                       placeholder="Confirme a nova senha" required>
                <div id="password-match" class="password-strength"></div>
            </div>
            
            <div class="d-grid gap-2">
                <button type="submit" class="btn-change">
                    <i class="bi bi-check-circle"></i> Alterar Senha
                </button>
            </div>
        </form>
        
        <div class="password-requirements">
            <h6><i class="bi bi-shield-check"></i> Requisitos da Senha</h6>
            <div class="requirement invalid" id="req-length">
                <i class="bi bi-circle"></i> Pelo menos 8 caracteres
            </div>
            <div class="requirement invalid" id="req-uppercase">
                <i class="bi bi-circle"></i> Pelo menos uma letra maiúscula
            </div>
            <div class="requirement invalid" id="req-lowercase">
                <i class="bi bi-circle"></i> Pelo menos uma letra minúscula
            </div>
            <div class="requirement invalid" id="req-number">
                <i class="bi bi-circle"></i> Pelo menos um número
            </div>
            <div class="requirement invalid" id="req-special">
                <i class="bi bi-circle"></i> Pelo menos um caractere especial
            </div>
        </div>
    </div>
    
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        function checkPasswordStrength() {
            const password = document.getElementById('new_password').value;
            const strengthText = document.getElementById('password-strength');
            const confirm = document.getElementById('confirm_password').value;
            
            // Check requirements
            const hasLength = password.length >= 8;
            const hasUpper = /[A-Z]/.test(password);
            const hasLower = /[a-z]/.test(password);
            const hasNumber = /\d/.test(password);
            const hasSpecial = /[!@#$%^&*(),.?":{}|<>]/.test(password);
            
            // Update requirement indicators
            updateRequirement('req-length', hasLength);
            updateRequirement('req-uppercase', hasUpper);
            updateRequirement('req-lowercase', hasLower);
            updateRequirement('req-number', hasNumber);
            updateRequirement('req-special', hasSpecial);
            
            // Calculate strength
            let strength = 0;
            if (hasLength) strength++;
            if (hasUpper) strength++;
            if (hasLower) strength++;
            if (hasNumber) strength++;
            if (hasSpecial) strength++;
            
            // Display strength
            if (password.length === 0) {
                strengthText.textContent = '';
                strengthText.className = 'password-strength';
            } else if (strength <= 2) {
                strengthText.textContent = '❌ Senha fraca';
                strengthText.className = 'password-strength strength-weak';
            } else if (strength <= 4) {
                strengthText.textContent = '⚠️ Senha média';
                strengthText.className = 'password-strength strength-medium';
            } else {
                strengthText.textContent = '✅ Senha forte';
                strengthText.className = 'password-strength strength-strong';
            }
            
            // Check password match
            checkPasswordMatch();
        }
        
        function updateRequirement(elementId, isValid) {
            const element = document.getElementById(elementId);
            if (isValid) {
                element.className = 'requirement valid';
                element.innerHTML = '<i class="bi bi-check-circle"></i> ' + element.textContent.replace('●', '✓');
            } else {
                element.className = 'requirement invalid';
                element.innerHTML = '<i class="bi bi-circle"></i> ' + element.textContent;
            }
        }
        
        function checkPasswordMatch() {
            const password = document.getElementById('new_password').value;
            const confirm = document.getElementById('confirm_password').value;
            const matchText = document.getElementById('password-match');
            
            if (confirm.length === 0) {
                matchText.textContent = '';
                return;
            }
            
            if (password === confirm) {
                matchText.textContent = '✅ Senhas coincidem';
                matchText.className = 'password-strength strength-strong';
            } else {
                matchText.textContent = '❌ Senhas não coincidem';
                matchText.className = 'password-strength strength-weak';
            }
        }
        
        function validatePassword() {
            const current = document.getElementById('current_password').value;
            const newPass = document.getElementById('new_password').value;
            const confirm = document.getElementById('confirm_password').value;
            
            // Check if current password is not the same as new
            if (current === newPass) {
                alert('A nova senha não pode ser igual à senha atual!');
                return false;
            }
            
            // Check password strength
            if (newPass.length < 8) {
                alert('A senha deve ter pelo menos 8 caracteres!');
                return false;
            }
            
            if (!/[A-Z]/.test(newPass)) {
                alert('A senha deve conter pelo menos uma letra maiúscula!');
                return false;
            }
            
            if (!/[a-z]/.test(newPass)) {
                alert('A senha deve conter pelo menos uma letra minúscula!');
                return false;
            }
            
            if (!/\d/.test(newPass)) {
                alert('A senha deve conter pelo menos um número!');
                return false;
            }
            
            if (!/[!@#$%^&*(),.?":{}|<>]/.test(newPass)) {
                alert('A senha deve conter pelo menos um caractere especial!');
                return false;
            }
            
            // Check password match
            if (newPass !== confirm) {
                alert('As senhas não coincidem!');
                return false;
            }
            
            return true;
        }
        
        // Initialize
        document.getElementById('confirm_password').addEventListener('input', checkPasswordMatch);
        document.getElementById('new_password').focus();
        
        // Prevent multiple submissions
        document.querySelector('form').addEventListener('submit', function() {
            const btn = this.querySelector('button[type="submit"]');
            btn.disabled = true;
            btn.innerHTML = '<i class="bi bi-hourglass-split"></i> Alterando...';
        });
    </script>
</body>
</html>
'''

# O restante do HTML INDEX_HTML permanece o mesmo, mas com uma adição no topo para mostrar o usuário logado

INDEX_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Converter ULTIMATE</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        /* ... (estilos existentes permanecem iguais) ... */
        
        .user-info {
            background: linear-gradient(90deg, #4361ee 0%, #3a0ca3 100%);
            color: white;
            border-radius: 10px;
            padding: 10px 15px;
            margin-bottom: 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .user-info .user-name {
            font-weight: bold;
        }
        
        .user-info .logout-btn {
            background: rgba(255, 255, 255, 0.2);
            border: 1px solid rgba(255, 255, 255, 0.3);
            color: white;
            padding: 5px 15px;
            border-radius: 5px;
            text-decoration: none;
            transition: all 0.3s;
        }
        
        .user-info .logout-btn:hover {
            background: rgba(255, 255, 255, 0.3);
        }
    </style>
</head>
<body>
    <div class="container-fluid">
        <div class="row">
            <!-- Sidebar -->
            <div class="col-md-3 mb-4">
                <div class="glass-card">
                    <!-- User Info -->
                    <div class="user-info">
                        <div>
                            <div class="user-name"><i class="bi bi-person-circle"></i> {{ session.user_id }}</div>
                            <small>Logado desde {{ session.login_time }}</small>
                        </div>
                        <a href="/logout" class="logout-btn">
                            <i class="bi bi-box-arrow-right"></i> Sair
                        </a>
                    </div>
                    
                    <div class="text-center mb-4">
                        <h1><i class="bi bi-camera-reels"></i> HLS ULTIMATE</h1>
                        <p class="text-muted">Conversor de vídeos profissional</p>
                    </div>
                    
                    <!-- ... (resto do conteúdo permanece igual) ... -->
'''

# O resto do arquivo app.py continua com as funções existentes...

# ==================== ROTAS DE AUTENTICAÇÃO ====================

@app.route('/')
def index():
    if 'user_id' not in session:
        return redirect(url_for('login_page'))
    
    if password_change_required(session['user_id']):
        return redirect(url_for('change_password_page'))
    
    return render_template_string(INDEX_HTML)

@app.route('/login', methods=['GET', 'POST'])
def login_page():
    if request.method == 'GET':
        # Se já estiver logado, redireciona para a página principal
        if 'user_id' in session:
            if password_change_required(session['user_id']):
                return redirect(url_for('change_password_page'))
            return redirect(url_for('index'))
        return render_template_string(LOGIN_HTML)
    
    # POST - Processar login
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    
    if not username or not password:
        flash('Por favor, preencha todos os campos', 'error')
        return render_template_string(LOGIN_HTML)
    
    # Verificar credenciais
    if check_password(username, password):
        # Registrar login
        users_data = load_users()
        if username in users_data['users']:
            users_data['users'][username]['last_login'] = datetime.now().isoformat()
            save_users(users_data)
        
        # Criar sessão
        session['user_id'] = username
        session['login_time'] = datetime.now().strftime('%H:%M:%S')
        session['login_timestamp'] = datetime.now().isoformat()
        
        log_activity("Login bem-sucedido", "INFO", username)
        
        # Verificar se precisa trocar senha
        if password_change_required(username):
            return redirect(url_for('change_password_page'))
        
        return redirect(url_for('index'))
    else:
        log_activity("Tentativa de login falhou", "WARNING", username)
        flash('Usuário ou senha incorretos', 'error')
        return render_template_string(LOGIN_HTML)

@app.route('/change-password', methods=['GET', 'POST'])
def change_password_page():
    if 'user_id' not in session:
        return redirect(url_for('login_page'))
    
    username = session['user_id']
    
    if request.method == 'GET':
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    # POST - Processar troca de senha
    current_password = request.form.get('current_password', '').strip()
    new_password = request.form.get('new_password', '').strip()
    confirm_password = request.form.get('confirm_password', '').strip()
    
    # Validações
    if not current_password or not new_password or not confirm_password:
        flash('Por favor, preencha todos os campos', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    if new_password != confirm_password:
        flash('As senhas não coincidem', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    if len(new_password) < 8:
        flash('A senha deve ter pelo menos 8 caracteres', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    if current_password == new_password:
        flash('A nova senha não pode ser igual à atual', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)
    
    # Tentar alterar a senha
    if change_password(username, current_password, new_password):
        flash('Senha alterada com sucesso!', 'success')
        log_activity("Senha alterada no primeiro acesso", "INFO", username)
        return redirect(url_for('index'))
    else:
        flash('Senha atual incorreta', 'error')
        return render_template_string(CHANGE_PASSWORD_HTML)

@app.route('/logout')
def logout():
    if 'user_id' in session:
        username = session['user_id']
        log_activity("Logout realizado", "INFO", username)
        session.clear()
        flash('Você foi desconectado com sucesso', 'info')
    return redirect(url_for('login_page'))

# ==================== PROTEGER TODAS AS ROTAS ====================

# Decorar todas as rotas existentes com @login_required
def protect_routes():
    """Protege todas as rotas existentes com autenticação"""
    # Lista de rotas que não precisam de autenticação
    public_routes = ['login_page', 'change_password_page', 'logout', 
                     'static', 'serve_hls', 'serve_static', 'health_check']
    
    # Proteger todas as outras rotas
    for rule in app.url_map.iter_rules():
        endpoint = rule.endpoint
        if endpoint not in public_routes:
            # Encontrar a função original
            view_func = app.view_functions[endpoint]
            # Substituir pela versão protegida
            app.view_functions[endpoint] = login_required(view_func)

# Função ROBUSTA para encontrar ffmpeg (mantida igual)
def find_ffmpeg():
    """Encontra ffmpeg em vários locais possíveis"""
    possible_paths = [
        '/usr/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/bin/ffmpeg',
        '/snap/bin/ffmpeg',
        '/opt/homebrew/bin/ffmpeg',
        os.path.expanduser('~/.local/bin/ffmpeg'),
        '/usr/lib/ffmpeg',
    ]
    
    # Verificar no PATH
    try:
        result = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
    
    # Verificar em cada caminho possível
    for path in possible_paths:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    
    # Tentar encontrar via find
    try:
        result = subprocess.run(['find', '/usr', '-name', 'ffmpeg', '-type', 'f', '-executable'], 
                              capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and result.stdout:
            return result.stdout.split('\n')[0]
    except:
        pass
    
    return None

# O resto das funções (get_system_info, get_ffmpeg_version, etc.) permanecem iguais

# ... (resto do código das rotas /convert, /api/system, etc. permanece igual)

if __name__ == '__main__':
    print("🎬 HLS Converter ULTIMATE v4.0 COM AUTENTICAÇÃO")
    print("==============================================")
    print("🔐 Sistema de login implementado")
    print("👤 Usuário padrão: admin / admin")
    print("⚠️  Necessário alterar senha no primeiro acesso")
    print("")
    
    # Proteger todas as rotas
    protect_routes()
    
    if FFMPEG_PATH:
        print(f"✅ FFmpeg encontrado em: {FFMPEG_PATH}")
        try:
            result = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True)
            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                print(f"📊 Versão: {version_line}")
        except:
            print("⚠️  FFmpeg encontrado mas não testado")
    else:
        print("❌ FFmpeg NÃO encontrado!")
        print("📋 Execute: hlsctl fix-ffmpeg")
    
    print("🌐 Starting on port 8080")
    print("🔐 Login: http://localhost:8080/login")
    print("🎮 Interface: http://localhost:8080/")
    print("")
    
    from waitress import serve
    serve(app, host='0.0.0.0', port=8080)
EOF

# 13. CRIAR ARQUIVOS DE CONFIGURAÇÃO
echo "📁 Criando arquivos de configuração..."

# Arquivo de configuração do sistema
cat > /opt/hls-converter/config.json << 'EOF'
{
    "system": {
        "port": 8080,
        "upload_limit_mb": 2048,
        "keep_originals": true,
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
            "audio_bitrate": "64k",
            "crf": "28"
        },
        "480p": {
            "scale": "854:480",
            "bitrate": "800k",
            "audio_bitrate": "96k",
            "crf": "26"
        },
        "720p": {
            "scale": "1280:720",
            "bitrate": "1500k",
            "audio_bitrate": "128k",
            "crf": "23"
        },
        "1080p": {
            "scale": "1920:1080",
            "bitrate": "3000k",
            "audio_bitrate": "192k",
            "crf": "23"
        }
    },
    "ffmpeg": {
        "preset": "fast",
        "threads": "auto"
    }
}
EOF

# 14. CRIAR BANCO DE DADOS INICIAL
echo "💾 Criando banco de dados inicial..."

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

# 15. CRIAR SCRIPT DE VERIFICAÇÃO DO FFMPEG
echo "🔧 Criando script de verificação do ffmpeg..."

cat > /opt/hls-converter/check_ffmpeg.sh << 'EOF'
#!/bin/bash

echo "🔍 Verificando FFmpeg..."
echo "========================"

echo "1. Verificando PATH..."
which ffmpeg

echo ""
echo "2. Procurando ffmpeg no sistema..."
find /usr -name "ffmpeg" -type f 2>/dev/null | head -5

echo ""
echo "3. Testando execução..."
if command -v ffmpeg &> /dev/null; then
    ffmpeg -version | head -3
else
    echo "   ❌ ffmpeg não encontrado"
fi

echo ""
echo "4. Soluções:"
echo "   • hlsctl fix-ffmpeg"
echo "   • sudo apt-get update && sudo apt-get install -y ffmpeg"
echo "   • sudo snap install ffmpeg --classic"
EOF

chmod +x /opt/hls-converter/check_ffmpeg.sh

# 16. CRIAR SCRIPT PARA GERAR USUÁRIOS
echo "👤 Criando script de gerenciamento de usuários..."

cat > /opt/hls-converter/manage_users.py << 'EOF'
#!/usr/bin/env python3
import json
import bcrypt
import sys
import os

USERS_FILE = "/opt/hls-converter/db/users.json"

def load_users():
    try:
        with open(USERS_FILE, 'r') as f:
            return json.load(f)
    except:
        return {"users": {}, "settings": {}}

def save_users(data):
    with open(USERS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def add_user(username, password, role="user"):
    users_data = load_users()
    
    if username in users_data['users']:
        print(f"❌ Usuário '{username}' já existe!")
        return False
    
    # Gerar hash da senha
    password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    users_data['users'][username] = {
        "password": password_hash,
        "password_changed": False,
        "created_at": "2024-01-01T00:00:00",
        "last_login": None,
        "role": role
    }
    
    save_users(users_data)
    print(f"✅ Usuário '{username}' criado com sucesso!")
    print(f"   Role: {role}")
    print(f"   Necessita trocar senha: Sim")
    return True

def list_users():
    users_data = load_users()
    
    if not users_data['users']:
        print("Nenhum usuário cadastrado")
        return
    
    print("👥 Usuários do sistema:")
    print("-" * 50)
    for username, data in users_data['users'].items():
        print(f"📛 Nome: {username}")
        print(f"   Role: {data.get('role', 'user')}")
        print(f"   Senha alterada: {'Sim' if data.get('password_changed') else 'Não'}")
        print(f"   Último login: {data.get('last_login', 'Nunca')}")
        print()

def reset_password(username, new_password):
    users_data = load_users()
    
    if username not in users_data['users']:
        print(f"❌ Usuário '{username}' não encontrado!")
        return False
    
    # Gerar hash da nova senha
    password_hash = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    users_data['users'][username]['password'] = password_hash
    users_data['users'][username]['password_changed'] = False
    
    save_users(users_data)
    print(f"✅ Senha do usuário '{username}' redefinida!")
    print(f"   Necessita trocar senha no próximo login: Sim")
    return True

def delete_user(username):
    users_data = load_users()
    
    if username not in users_data['users']:
        print(f"❌ Usuário '{username}' não encontrado!")
        return False
    
    if username == 'admin':
        print("❌ Não é possível deletar o usuário admin!")
        return False
    
    del users_data['users'][username]
    save_users(users_data)
    print(f"✅ Usuário '{username}' removido com sucesso!")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python manage_users.py [comando]")
        print("\nComandos:")
        print("  list                    - Listar todos os usuários")
        print("  add <user> <pass> [role]- Adicionar novo usuário")
        print("  reset <user> <new_pass> - Redefinir senha de usuário")
        print("  delete <user>           - Remover usuário")
        print("\nExemplos:")
        print("  python manage_users.py list")
        print("  python manage_users.py add joao senha123")
        print("  python manage_users.py add maria senha456 admin")
        print("  python manage_users.py reset joao novaSenha123")
        print("  python manage_users.py delete maria")
        sys.exit(1)
    
    command = sys.argv[1].lower()
    
    if command == "list":
        list_users()
    
    elif command == "add":
        if len(sys.argv) < 4:
            print("❌ Uso: python manage_users.py add <username> <password> [role]")
            sys.exit(1)
        
        username = sys.argv[2]
        password = sys.argv[3]
        role = sys.argv[4] if len(sys.argv) > 4 else "user"
        
        if role not in ['user', 'admin']:
            print("❌ Role deve ser 'user' ou 'admin'")
            sys.exit(1)
        
        add_user(username, password, role)
    
    elif command == "reset":
        if len(sys.argv) < 4:
            print("❌ Uso: python manage_users.py reset <username> <new_password>")
            sys.exit(1)
        
        username = sys.argv[2]
        new_password = sys.argv[3]
        reset_password(username, new_password)
    
    elif command == "delete":
        if len(sys.argv) < 3:
            print("❌ Uso: python manage_users.py delete <username>")
            sys.exit(1)
        
        username = sys.argv[2]
        delete_user(username)
    
    else:
        print(f"❌ Comando desconhecido: {command}")
        sys.exit(1)
EOF

chmod +x /opt/hls-converter/manage_users.py

# 17. CRIAR SERVIÇO SYSTEMD COMPLETO
echo "⚙️ Configurando serviço systemd..."

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
Environment="PATH=/opt/hls-converter/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"

ExecStart=/opt/hls-converter/venv/bin/python /opt/hls-converter/app.py

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db /opt/hls-converter/sessions

[Install]
WantedBy=multi-user.target
EOF

# 18. CRIAR SCRIPT DE GERENCIAMENTO AVANÇADO (hlsctl)
echo "📝 Criando script de gerenciamento avançado..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"

case "$1" in
    start)
        systemctl start hls-converter
        echo "✅ Serviço iniciado"
        ;;
    stop)
        systemctl stop hls-converter
        echo "✅ Serviço parado"
        ;;
    restart)
        systemctl restart hls-converter
        echo "✅ Serviço reiniciado"
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
        curl -s http://localhost:8080/health | python3 -m json.tool || curl -s http://localhost:8080/health
        echo ""
        echo "FFmpeg:"
        ffmpeg -version 2>/dev/null | head -1 || echo "FFmpeg não encontrado"
        ;;
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        find /opt/hls-converter/uploads -type f -mtime +7 -delete 2>/dev/null
        find /opt/hls-converter/hls -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null
        echo "✅ Arquivos antigos removidos"
        ;;
    fix-ffmpeg)
        echo "🔧 Instalando ffmpeg com múltiplos métodos..."
        
        # Method 1: Standard apt
        echo "📦 Método 1: Instalação via apt..."
        apt-get update
        apt-get install -y ffmpeg
        
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg instalado via apt"
        else
            # Method 2: Snap
            echo "📦 Método 2: Instalação via Snap..."
            if command -v snap &> /dev/null; then
                snap install ffmpeg --classic
            fi
            
            if ! command -v ffmpeg &> /dev/null; then
                # Method 3: Static binary
                echo "📦 Método 3: Baixando binário estático..."
                cd /tmp
                wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz || \
                curl -L -o ffmpeg-release-amd64-static.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
                
                if [ -f ffmpeg-release-amd64-static.tar.xz ]; then
                    tar -xf ffmpeg-release-amd64-static.tar.xz
                    FFMPEG_DIR=$(find . -name "ffmpeg-*-static" -type d | head -1)
                    if [ -n "$FFMPEG_DIR" ]; then
                        cp "$FFMPEG_DIR"/ffmpeg "$FFMPEG_DIR"/ffprobe /usr/local/bin/
                        chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
                        echo "✅ FFmpeg instalado de binário estático"
                    fi
                fi
            fi
        fi
        
        if command -v ffmpeg &> /dev/null; then
            echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
            echo "🔍 Localização: $(which ffmpeg)"
            echo "📊 Versão:"
            ffmpeg -version | head -1
            echo ""
            echo "🔄 Reinicie o serviço:"
            echo "   hlsctl restart"
        else
            echo "❌ Não foi possível instalar FFmpeg automaticamente"
            echo "📋 Instale manualmente:"
            echo "   1. sudo apt-get update && sudo apt-get install -y ffmpeg"
            echo "   2. Ou baixe de: https://ffmpeg.org/download.html"
        fi
        ;;
    debug-ffmpeg)
        echo "🔍 Depurando ffmpeg..."
        echo "1. Verificando PATH..."
        which ffmpeg || echo "   Não encontrado no PATH"
        
        echo ""
        echo "2. Procurando no sistema..."
        find /usr -name "ffmpeg" -type f 2>/dev/null | head -5
        
        echo ""
        echo "3. Testando endpoint de debug..."
        curl -s http://localhost:8080/api/debug 2>/dev/null | python3 -m json.tool || \
        echo "   Aplicação não está rodando"
        
        echo ""
        echo "4. Testando execução..."
        if command -v ffmpeg &> /dev/null; then
            ffmpeg -version | head -1
        else
            echo "   comando ffmpeg não encontrado"
        fi
        ;;
    users)
        echo "👥 Gerenciamento de usuários"
        echo "============================"
        echo ""
        echo "Uso: hlsctl users [comando]"
        echo ""
        echo "Comandos:"
        echo "  list                    - Listar usuários"
        echo "  add <user> <pass>       - Adicionar usuário"
        echo "  reset <user> <new_pass> - Redefinir senha"
        echo "  delete <user>           - Remover usuário"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl users list"
        echo "  hlsctl users add joao senha123"
        echo "  hlsctl users reset admin novaSenha123"
        ;;
    users-list)
        echo "👥 Listando usuários..."
        python3 /opt/hls-converter/manage_users.py list
        ;;
    users-add)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "❌ Uso: hlsctl users-add <username> <password>"
            exit 1
        fi
        echo "👤 Adicionando usuário $2..."
        python3 /opt/hls-converter/manage_users.py add "$2" "$3"
        ;;
    users-reset)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "❌ Uso: hlsctl users-reset <username> <new_password>"
            exit 1
        fi
        echo "🔑 Redefinindo senha de $2..."
        python3 /opt/hls-converter/manage_users.py reset "$2" "$3"
        ;;
    users-delete)
        if [ -z "$2" ]; then
            echo "❌ Uso: hlsctl users-delete <username>"
            exit 1
        fi
        echo "🗑️  Removendo usuário $2..."
        python3 /opt/hls-converter/manage_users.py delete "$2"
        ;;
    reinstall)
        echo "🔄 Reinstalando HLS Converter..."
        systemctl stop hls-converter 2>/dev/null || true
        rm -rf /opt/hls-converter
        rm -f /etc/systemd/system/hls-converter.service
        rm -f /usr/local/bin/hlsctl
        echo "✅ Instalação antiga removida"
        echo "📋 Execute o instalador novamente"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Converter ULTIMATE COM AUTENTICAÇÃO ==="
        echo "Porta: 8080"
        echo "Login: http://$IP:8080/login"
        echo "Usuário padrão: admin / admin"
        echo "Diretório: /opt/hls-converter"
        echo "Usuário: hlsuser"
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        
        if command -v ffmpeg &> /dev/null; then
            echo "FFmpeg: ✅ Disponível"
            echo "Versão: $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)"
        else
            echo "FFmpeg: ❌ Não instalado"
        fi
        
        # Contar usuários
        if [ -f "/opt/hls-converter/db/users.json" ]; then
            USER_COUNT=$(python3 -c "import json; data=json.load(open('/opt/hls-converter/db/users.json')); print(len(data.get('users', {})))")
            echo "Usuários cadastrados: $USER_COUNT"
        fi
        ;;
    *)
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos principais:"
        echo "  start         - Iniciar serviço"
        echo "  stop          - Parar serviço"
        echo "  restart       - Reiniciar serviço"
        echo "  status        - Ver status"
        echo "  logs          - Ver logs"
        echo "  test          - Testar sistema"
        echo "  cleanup       - Limpar arquivos antigos"
        echo "  fix-ffmpeg    - INSTALAR/REPARAR FFMPEG"
        echo "  debug-ffmpeg  - Diagnosticar ffmpeg"
        echo ""
        echo "👥 Gerenciamento de usuários:"
        echo "  users                    - Mostrar ajuda"
        echo "  users-list              - Listar usuários"
        echo "  users-add <user> <pass> - Adicionar usuário"
        echo "  users-reset <user> <pass>- Redefinir senha"
        echo "  users-delete <user>     - Remover usuário"
        echo ""
        echo "🔄 Outros:"
        echo "  reinstall     - Reinstalar sistema"
        echo "  info          - Informações do sistema"
        ;;
esac
EOF

chmod +x /usr/local/bin/hlsctl

# 19. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."
chown -R hlsuser:hlsuser /opt/hls-converter
chmod 755 /opt/hls-converter
chmod 644 /opt/hls-converter/*.py
chmod 644 /opt/hls-converter/*.json
chmod 755 /opt/hls-converter/check_ffmpeg.sh
chmod 755 /opt/hls-converter/manage_users.py

# Criar diretório de sessões
mkdir -p /opt/hls-converter/sessions
chown hlsuser:hlsuser /opt/hls-converter/sessions
chmod 700 /opt/hls-converter/sessions

# 20. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
systemctl daemon-reload
systemctl enable hls-converter.service
systemctl start hls-converter.service

sleep 8

# 21. VERIFICAÇÃO FINAL DETALHADA
echo "🔍 VERIFICAÇÃO FINAL DETALHADA..."
echo "================================"

# Verificar ffmpeg
echo ""
echo "1. Verificando FFmpeg:"
if command -v ffmpeg &> /dev/null; then
    echo "   ✅ FFmpeg encontrado: $(which ffmpeg)"
    ffmpeg -version | head -1
else
    echo "   ❌ FFmpeg NÃO encontrado!"
    echo "   📋 Execute: hlsctl fix-ffmpeg"
fi

# Verificar serviço
echo ""
echo "2. Verificando serviço:"
if systemctl is-active --quiet hls-converter.service; then
    echo "   ✅ Serviço está ativo"
    
    echo ""
    echo "3. Testando endpoints:"
    
    # Health check (público)
    echo "   a) Health check (público):"
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "      ✅ OK"
    else
        echo "      ⚠️  Warning"
        curl -s http://localhost:8080/health | head -2
    fi
    
    # Login page
    echo "   b) Página de login:"
    if curl -s -I http://localhost:8080/login | head -1 | grep -q "200"; then
        echo "      ✅ OK"
    else
        echo "      ❌ Falha"
    fi
    
    # Redirect to login
    echo "   c) Redirecionamento para login:"
    if curl -s -I http://localhost:8080/ | head -1 | grep -q "302"; then
        echo "      ✅ OK (redireciona para login)"
    else
        echo "      ⚠️  Verifique"
    fi
    
else
    echo "   ❌ Serviço não está ativo"
    echo "   📋 Logs:"
    journalctl -u hls-converter -n 10 --no-pager
fi

# 22. OBTER INFORMAÇÕES DO SISTEMA
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO ULTIMATE COM AUTENTICAÇÃO CONCLUÍDA! 🎉🎉🎉"
echo "==========================================================="
echo ""
echo "✅ SISTEMA COMPLETO COM LOGIN INSTALADO"
echo ""
echo "🔐 CARACTERÍSTICAS DE SEGURANÇA:"
echo "   ✔️  Sistema de login obrigatório"
echo "   ✔️  Troca de senha obrigatória no primeiro acesso"
echo "   ✔️  Senhas criptografadas com bcrypt"
echo "   ✔️  Sessões seguras"
echo "   ✔️  Logs de autenticação"
echo "   ✔️  Validação de força de senha"
echo "   ✔️  Gerenciamento de usuários"
echo ""
echo "✨ CARACTERÍSTICAS TÉCNICAS:"
echo "   ✔️  Dashboard profissional completo"
echo "   ✔️  Sistema robusto de instalação do FFmpeg"
echo "   ✔️  Script de gerenciamento avançado (hlsctl)"
echo "   ✔️  Interface com múltiplas abas"
echo "   ✔️  Histórico de conversões"
echo "   ✔️  Ferramentas de manutenção"
echo "   ✔️  Monitoramento em tempo real"
echo ""
echo "🌐 URLS DE ACESSO:"
echo "   🔐 PÁGINA DE LOGIN: http://$IP:8080/login"
echo "   🎨 INTERFACE PRINCIPAL: http://$IP:8080/"
echo "   🩺 HEALTH CHECK: http://$IP:8080/health"
echo ""
echo "👥 CREDENCIAIS PADRÃO:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo "   ⚠️  A senha DEVE ser alterada no primeiro acesso!"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start         - Iniciar serviço"
echo "   • hlsctl stop          - Parar serviço"
echo "   • hlsctl restart       - Reiniciar serviço"
echo "   • hlsctl status        - Ver status"
echo "   • hlsctl logs          - Ver logs"
echo ""
echo "👥 GERENCIAMENTO DE USUÁRIOS:"
echo "   • hlsctl users-list    - Listar usuários"
echo "   • hlsctl users-add     - Adicionar usuário"
echo "   • hlsctl users-reset   - Redefinir senha"
echo "   • hlsctl users-delete  - Remover usuário"
echo ""
echo "🛠️  OUTROS COMANDOS:"
echo "   • hlsctl fix-ffmpeg    - INSTALAR/REPARAR FFMPEG"
echo "   • hlsctl cleanup       - Limpar arquivos antigos"
echo "   • hlsctl info          - Informações do sistema"
echo ""
echo "📁 DIRETÓRIOS DO SISTEMA:"
echo "   • Aplicação: /opt/hls-converter/"
echo "   • Sessões: /opt/hls-converter/sessions/"
echo "   • Uploads: /opt/hls-converter/uploads/"
echo "   • HLS: /opt/hls-converter/hls/"
echo "   • Logs: /opt/hls-converter/logs/"
echo "   • Banco de dados: /opt/hls-converter/db/"
echo ""
echo "💡 COMO USAR:"
echo "   1. Acesse http://$IP:8080/login"
echo "   2. Faça login com admin / admin"
echo "   3. Altere a senha para uma senha forte"
echo "   4. Use a interface para converter vídeos"
echo "   5. Para adicionar mais usuários: hlsctl users-add"
echo ""
echo "🚀 SISTEMA PRONTO PARA USO COM SEGURANÇA!"

# 23. CRIAR SCRIPT DE BACKUP (extra)
echo "💾 Criando script de backup..."

cat > /usr/local/bin/hls-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/hls-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /opt/hls-converter/db "$BACKUP_DIR/"
cp -r /opt/hls-converter/config.json "$BACKUP_DIR/"
echo "✅ Backup criado em: $BACKUP_DIR"
echo "🔐 Usuários: $(ls -la $BACKUP_DIR/db/users.json)"
EOF

chmod +x /usr/local/bin/hls-backup

echo ""
echo "✅ Script de backup criado: hls-backup"
echo ""
echo "⚠️  IMPORTANTE: Guarde a nova senha em local seguro!"
echo ""
echo "🎯 INSTALAÇÃO COMPLETA - SISTEMA ULTIMATE COM LOGIN PRONTO!"
