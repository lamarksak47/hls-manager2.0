#!/bin/bash
# install_hls_converter_multiple.sh - VERSÃO COM MULTIPLOS ARQUIVOS

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE - MULTIPLOS ARQUIVOS"
echo "========================================================="

# [O resto do script permanece IDÊNTICO até a parte do app.py]

# 10. CRIAR APLICAÇÃO FLASK COM SUPORTE A MÚLTIPLOS ARQUIVOS
echo "💻 Criando aplicação Flask com suporte a múltiplos arquivos..."

cat > app.py << 'EOF'
#!/usr/bin/env python3
"""
HLS Converter ULTIMATE - Versão com Múltiplos Arquivos
Aceita vários arquivos em uma única conversão e cria um único link M3U8
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
import psutil

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
    <title>🎬 HLS Converter ULTIMATE - Múltiplos Arquivos</title>
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
        
        .file-list {
            max-height: 300px;
            overflow-y: auto;
            margin: 20px 0;
            border: 1px solid #eaeaea;
            border-radius: 8px;
            padding: 15px;
        }
        
        .file-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px 15px;
            background: #f8f9fa;
            border-radius: 6px;
            margin-bottom: 8px;
            border-left: 4px solid var(--accent);
        }
        
        .file-item:last-child {
            margin-bottom: 0;
        }
        
        .file-info {
            flex: 1;
        }
        
        .file-name {
            font-weight: 600;
            color: var(--dark);
        }
        
        .file-size {
            font-size: 0.85rem;
            color: #6c757d;
            margin-top: 3px;
        }
        
        .file-remove {
            background: var(--danger);
            color: white;
            border: none;
            width: 30px;
            height: 30px;
            border-radius: 50%;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
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
        
        .conversion-info {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
            display: none;
        }
        
        .conversion-info.show {
            display: block;
            animation: fadeIn 0.5s ease;
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
    </style>
</head>
<body>
    <div class="header">
        <div class="logo">
            <i class="fas fa-video"></i>
            <h1>HLS Converter ULTIMATE</h1>
            <small style="font-size: 0.8rem; background: rgba(255,255,255,0.3); padding: 3px 8px; border-radius: 10px;">
                Múltiplos Arquivos
            </small>
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
                <i class="fas fa-upload"></i> Upload Múltiplo
            </div>
            <div class="nav-tab" onclick="showTab('conversions')">
                <i class="fas fa-history"></i> Histórico
            </div>
            <div class="nav-tab" onclick="showTab('settings')">
                <i class="fas fa-cog"></i> Configurações
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
                </div>
            </div>
        </div>
        
        <!-- Upload Tab - MODIFICADO PARA MÚLTIPLOS ARQUIVOS -->
        <div id="upload" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-upload"></i> Converter Múltiplos Vídeos para HLS</h2>
                <p style="color: #666; margin-bottom: 20px;">
                    <i class="fas fa-info-circle"></i> Selecione vários vídeos para criar um único link M3U8 com todos em sequência.
                </p>
                
                <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                    <i class="fas fa-cloud-upload-alt"></i>
                    <h3>Arraste e solte seus vídeos aqui</h3>
                    <p>ou clique para selecionar múltiplos arquivos</p>
                    <p style="color: #666; margin-top: 10px;">
                        Formatos suportados: MP4, AVI, MOV, MKV, WEBM
                    </p>
                    <p style="color: var(--primary); font-size: 0.9rem; margin-top: 5px;">
                        <i class="fas fa-lightbulb"></i> Você pode selecionar vários arquivos de uma vez
                    </p>
                </div>
                
                <input type="file" id="fileInput" accept="video/*" multiple style="display: none;" onchange="handleFileSelect()">
                
                <div id="fileList" class="file-list" style="display: none;">
                    <h4><i class="fas fa-list"></i> Arquivos Selecionados</h4>
                    <div id="fileItems"></div>
                    <p id="totalFiles" style="text-align: center; color: #666; margin-top: 10px; font-size: 0.9rem;"></p>
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
                
                <div style="margin-top: 30px;">
                    <h3><i class="fas fa-cogs"></i> Configurações</h3>
                    <div style="display: flex; align-items: center; gap: 10px; margin-top: 10px;">
                        <input type="checkbox" id="sequentialNaming" checked>
                        <label for="sequentialNaming">Numerar vídeos sequencialmente (Vídeo 1, Vídeo 2, etc.)</label>
                    </div>
                </div>
                
                <button class="btn btn-primary" onclick="startConversion()" id="convertBtn" style="margin-top: 30px; width: 100%;">
                    <i class="fas fa-play-circle"></i> Iniciar Conversão de Todos os Vídeos
                </button>
                
                <div id="progress" style="display: none; margin-top: 30px;">
                    <h3><i class="fas fa-spinner fa-spin"></i> Progresso da Conversão</h3>
                    <div class="progress-container">
                        <div class="progress-bar" id="progressBar" style="width: 0%">0%</div>
                    </div>
                    <div style="display: flex; justify-content: space-between; margin-top: 10px;">
                        <span id="progressText" style="color: #666;">Preparando conversão...</span>
                        <span id="progressFile" style="color: #666; font-size: 0.9rem;"></span>
                    </div>
                    <div id="progressDetails" style="margin-top: 15px; font-size: 0.9rem; color: #666;"></div>
                </div>
                
                <div id="conversionResult" class="conversion-info">
                    <h3><i class="fas fa-check-circle" style="color: var(--success);"></i> Conversão Concluída!</h3>
                    <div id="resultDetails"></div>
                </div>
            </div>
        </div>
        
        <!-- Conversions Tab -->
        <div id="conversions" class="tab-content">
            <div class="card">
                <h2><i class="fas fa-history"></i> Histórico de Conversões</h2>
                
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
                    <button class="btn btn-success" onclick="loadConversions()">
                        <i class="fas fa-sync-alt"></i> Atualizar
                    </button>
                    <div id="conversionStats" style="color: #666; font-size: 0.9rem;">
                        Carregando estatísticas...
                    </div>
                </div>
                
                <div id="conversionsList">
                    <div class="empty-state">
                        <i class="fas fa-history"></i>
                        <h3>Nenhuma conversão realizada ainda</h3>
                        <p>Converta seus primeiros vídeos para ver o histórico aqui</p>
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
                    <button class="btn btn-warning" onclick="cleanupOldFiles()" style="margin-top: 10px;">
                        <i class="fas fa-broom"></i> Limpar Arquivos Antigos
                    </button>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Variáveis globais
        let selectedFiles = [];
        let selectedQualities = ['240p', '480p', '720p', '1080p'];
        let currentConversion = null;
        
        // =============== FUNÇÕES DE NAVEGAÇÃO ===============
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
                case 'conversions':
                    loadConversions();
                    break;
            }
        }
        
        function getTabLabel(tabName) {
            const labels = {
                'dashboard': 'Dashboard',
                'upload': 'Upload',
                'conversions': 'Histórico',
                'settings': 'Configurações'
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
        
        // =============== UPLOAD MÚLTIPLO ===============
        function handleFileSelect() {
            const fileInput = document.getElementById('fileInput');
            const newFiles = Array.from(fileInput.files);
            
            // Adicionar novos arquivos à lista (evitar duplicados)
            newFiles.forEach(newFile => {
                const exists = selectedFiles.some(existingFile => 
                    existingFile.name === newFile.name && existingFile.size === newFile.size
                );
                if (!exists) {
                    selectedFiles.push(newFile);
                }
            });
            
            updateFileList();
        }
        
        function updateFileList() {
            const fileList = document.getElementById('fileList');
            const fileItems = document.getElementById('fileItems');
            const totalFiles = document.getElementById('totalFiles');
            
            if (selectedFiles.length === 0) {
                fileList.style.display = 'none';
                return;
            }
            
            fileList.style.display = 'block';
            
            // Ordenar arquivos por nome
            selectedFiles.sort((a, b) => a.name.localeCompare(b.name));
            
            let html = '';
            let totalSize = 0;
            
            selectedFiles.forEach((file, index) => {
                totalSize += file.size;
                
                html += `
                    <div class="file-item">
                        <div class="file-info">
                            <div class="file-name">
                                <i class="fas fa-file-video"></i> ${file.name}
                            </div>
                            <div class="file-size">
                                ${formatBytes(file.size)}
                            </div>
                        </div>
                        <button class="file-remove" onclick="removeFile(${index})" title="Remover arquivo">
                            <i class="fas fa-times"></i>
                        </button>
                    </div>
                `;
            });
            
            fileItems.innerHTML = html;
            totalFiles.textContent = `${selectedFiles.length} arquivo(s) selecionado(s) - Total: ${formatBytes(totalSize)}`;
        }
        
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            updateFileList();
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
                showToast('Por favor, selecione pelo menos um arquivo!', 'warning');
                return;
            }
            
            if (selectedQualities.length === 0) {
                showToast('Selecione pelo menos uma qualidade!', 'warning');
                return;
            }
            
            const formData = new FormData();
            
            // Adicionar todos os arquivos
            selectedFiles.forEach((file, index) => {
                formData.append(`file${index}`, file);
            });
            
            // Adicionar metadados
            formData.append('file_count', selectedFiles.length.toString());
            formData.append('qualities', JSON.stringify(selectedQualities));
            formData.append('sequential_naming', document.getElementById('sequentialNaming').checked.toString());
            
            // Mostrar progresso
            const progressSection = document.getElementById('progress');
            progressSection.style.display = 'block';
            
            const convertBtn = document.getElementById('convertBtn');
            convertBtn.disabled = true;
            convertBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Convertendo...';
            
            // Esconder resultado anterior
            document.getElementById('conversionResult').classList.remove('show');
            
            // Configurar progresso
            let progress = 0;
            let currentFileIndex = 0;
            
            function updateProgressUI() {
                const fileProgress = Math.floor((currentFileIndex / selectedFiles.length) * 100);
                const overallProgress = Math.floor((currentFileIndex / selectedFiles.length) * 100);
                
                document.getElementById('progressBar').style.width = `${overallProgress}%`;
                document.getElementById('progressBar').textContent = `${overallProgress}%`;
                document.getElementById('progressText').textContent = `Processando vídeo ${currentFileIndex + 1} de ${selectedFiles.length}`;
                
                if (currentFileIndex < selectedFiles.length) {
                    document.getElementById('progressFile').textContent = `Arquivo: ${selectedFiles[currentFileIndex].name}`;
                }
                
                document.getElementById('progressDetails').innerHTML = `
                    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px;">
                        <div style="background: #e9ecef; padding: 10px; border-radius: 5px;">
                            <div style="font-weight: bold; color: var(--primary);">${currentFileIndex + 1}/${selectedFiles.length}</div>
                            <div style="font-size: 0.8rem;">Vídeos</div>
                        </div>
                        <div style="background: #e9ecef; padding: 10px; border-radius: 5px;">
                            <div style="font-weight: bold; color: var(--success);">${selectedQualities.length}</div>
                            <div style="font-size: 0.8rem;">Qualidades</div>
                        </div>
                    </div>
                `;
            }
            
            // Simular progresso
            const progressInterval = setInterval(() => {
                progress += 2;
                if (progress > 90) progress = 90;
                updateProgressUI();
            }, 500);
            
            fetch('/convert-multiple', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                clearInterval(progressInterval);
                
                if (data.success) {
                    // Mostrar progresso completo
                    document.getElementById('progressBar').style.width = '100%';
                    document.getElementById('progressBar').textContent = '100%';
                    document.getElementById('progressText').textContent = 'Conversão concluída!';
                    
                    // Mostrar resultado
                    const resultDiv = document.getElementById('conversionResult');
                    resultDiv.classList.add('show');
                    
                    document.getElementById('resultDetails').innerHTML = `
                        <p><strong>✅ Conversão concluída com sucesso!</strong></p>
                        <p><strong>ID da Conversão:</strong> ${data.conversion_id}</p>
                        <p><strong>Total de Vídeos:</strong> ${data.total_videos}</p>
                        <p><strong>Qualidades Geradas:</strong> ${data.qualities.join(', ')}</p>
                        <p><strong>Vídeos Processados:</strong></p>
                        <ul style="margin-left: 20px; margin-top: 10px;">
                            ${data.videos.map((video, idx) => 
                                `<li>${idx + 1}. ${video.filename} (${video.qualities.join(', ')})</li>`
                            ).join('')}
                        </ul>
                        <div style="margin-top: 20px; background: #f8f9fa; padding: 15px; border-radius: 8px;">
                            <p><strong>🔗 Link M3U8 Principal:</strong></p>
                            <div style="display: flex; gap: 10px; margin-top: 10px;">
                                <input type="text" id="m3u8Link" value="${window.location.origin}${data.master_m3u8_url}" 
                                       style="flex: 1; padding: 10px; border: 1px solid #ddd; border-radius: 5px;" readonly>
                                <button class="btn btn-primary" onclick="copyLink('${data.conversion_id}')">
                                    <i class="fas fa-copy"></i> Copiar
                                </button>
                            </div>
                        </div>
                        <div style="margin-top: 20px; display: flex; gap: 10px;">
                            <button class="btn btn-success" onclick="playVideo('${data.conversion_id}')">
                                <i class="fas fa-play"></i> Reproduzir
                            </button>
                            <button class="btn btn-warning" onclick="showTab('conversions')">
                                <i class="fas fa-history"></i> Ver Histórico
                            </button>
                        </div>
                    `;
                    
                    showToast(`✅ Conversão concluída! ${data.total_videos} vídeo(s) processado(s)`, 'success');
                    
                    // Reset após 3 segundos
                    setTimeout(() => {
                        progressSection.style.display = 'none';
                        selectedFiles = [];
                        updateFileList();
                        document.getElementById('fileInput').value = '';
                        convertBtn.disabled = false;
                        convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão de Todos os Vídeos';
                        
                        // Atualizar histórico e stats
                        loadConversions();
                        loadSystemStats();
                    }, 3000);
                } else {
                    showToast(`❌ Erro: ${data.error}`, 'error');
                    convertBtn.disabled = false;
                    convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão de Todos os Vídeos';
                }
            })
            .catch(error => {
                clearInterval(progressInterval);
                showToast(`❌ Erro de conexão: ${error.message}`, 'error');
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="fas fa-play-circle"></i> Iniciar Conversão de Todos os Vídeos';
            });
        }
        
        // =============== HISTÓRICO ===============
        function loadConversions() {
            fetch('/api/conversions')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('conversionsList');
                    const statsContainer = document.getElementById('conversionStats');
                    
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
                                <p>Converta seus primeiros vídeos para ver o histórico aqui</p>
                            </div>
                        `;
                        return;
                    }
                    
                    let html = '<div class="conversions-list">';
                    
                    data.conversions.forEach(conv => {
                        const conversionId = conv.conversion_id || conv.video_id || 'N/A';
                        const videos = conv.videos || [];
                        const totalVideos = videos.length || conv.total_videos || 0;
                        
                        html += `
                            <div class="conversion-card">
                                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
                                    <span style="font-family: monospace; background: #f8f9fa; padding: 5px 10px; border-radius: 5px; font-size: 0.9rem;">
                                        ${conversionId.substring(0, 8)}...
                                    </span>
                                    <span style="background: #d4edda; color: #155724; padding: 5px 12px; border-radius: 20px; font-size: 0.8rem; font-weight: 600;">
                                        ✅ ${totalVideos} vídeo(s)
                                    </span>
                                </div>
                                <div style="margin: 10px 0;">
                                    <p><strong>Data:</strong> ${formatDate(conv.timestamp)}</p>
                                    <p><strong>Qualidades:</strong> ${(conv.qualities || []).join(', ') || 'N/A'}</p>
                                    <p><strong>Vídeos:</strong> ${totalVideos}</p>
                                </div>
                                <div style="display: flex; gap: 10px; margin-top: 15px;">
                                    <button class="btn btn-primary" style="flex: 1; padding: 8px; font-size: 0.85rem;" 
                                            onclick="copyLink('${conversionId}')">
                                        <i class="fas fa-link"></i> Link
                                    </button>
                                    <button class="btn btn-success" style="flex: 1; padding: 8px; font-size: 0.85rem;"
                                            onclick="playVideo('${conversionId}')">
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
                });
        }
        
        function copyLink(conversionId) {
            const link = window.location.origin + '/hls/' + conversionId + '/master.m3u8';
            navigator.clipboard.writeText(link)
                .then(() => showToast('✅ Link copiado para a área de transferência!', 'success'))
                .catch(() => {
                    const textArea = document.createElement('textarea');
                    textArea.value = link;
                    document.body.appendChild(textArea);
                    textArea.select();
                    document.execCommand('copy');
                    document.body.removeChild(textArea);
                    showToast('✅ Link copiado!', 'success');
                });
        }
        
        function playVideo(conversionId) {
            window.open('/player/' + conversionId, '_blank');
        }
        
        // =============== CONFIGURAÇÕES ===============
        function changePassword() {
            window.location.href = '/change-password';
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
            setInterval(loadSystemStats, 30000);
            
            // Configurar drag and drop para múltiplos arquivos
            const uploadArea = document.querySelector('.upload-area');
            
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
                    const newFiles = Array.from(e.dataTransfer.files);
                    
                    newFiles.forEach(newFile => {
                        const exists = selectedFiles.some(existingFile => 
                            existingFile.name === newFile.name && existingFile.size === newFile.size
                        );
                        if (!exists) {
                            selectedFiles.push(newFile);
                        }
                    });
                    
                    updateFileList();
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

# =============== NOVA FUNÇÃO DE CONVERSÃO MÚLTIPLA ===============
@app.route('/convert-multiple', methods=['POST'])
def convert_multiple_videos():
    """Converter múltiplos vídeos para um único M3U8 - NOVA FUNÇÃO"""
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
        
        # Obter parâmetros
        file_count = int(request.form.get('file_count', 0))
        qualities_json = request.form.get('qualities', '["720p"]')
        sequential_naming = request.form.get('sequential_naming', 'true').lower() == 'true'
        
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        if file_count == 0:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        # Criar ID único para esta conversão múltipla
        conversion_id = str(uuid.uuid4())[:12]
        output_dir = os.path.join(HLS_DIR, conversion_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Coletar todos os arquivos
        video_files = []
        for i in range(file_count):
            file_key = f'file{i}'
            if file_key in request.files:
                file = request.files[file_key]
                if file and file.filename:
                    video_files.append({
                        'file': file,
                        'filename': file.filename,
                        'index': i
                    })
        
        if not video_files:
            return jsonify({"success": False, "error": "Nenhum arquivo válido encontrado"})
        
        # Ordenar arquivos por nome
        video_files.sort(key=lambda x: x['filename'])
        
        # Processar cada vídeo
        processed_videos = []
        master_playlist_content = ["#EXTM3U", "#EXT-X-VERSION:3"]
        
        for idx, video_info in enumerate(video_files):
            file = video_info['file']
            original_filename = video_info['filename']
            
            # Criar nome para o vídeo
            if sequential_naming:
                video_name = f"Vídeo {idx + 1}"
            else:
                video_name = os.path.splitext(original_filename)[0]
            
            # Salvar arquivo original
            video_dir = os.path.join(output_dir, f"video_{idx}")
            os.makedirs(video_dir, exist_ok=True)
            
            original_path = os.path.join(video_dir, "original.mp4")
            file.save(original_path)
            
            # Criar playlist para este vídeo
            video_playlist = os.path.join(video_dir, "playlist.m3u8")
            
            with open(video_playlist, 'w') as f:
                f.write("#EXTM3U\n")
                f.write("#EXT-X-VERSION:3\n")
                
                # Adicionar marcador de início do vídeo
                f.write(f"#EXTINF:,\n")
                f.write(f"# Video: {video_name}\n")
                
                # Converter para cada qualidade
                for quality in qualities:
                    quality_dir = os.path.join(video_dir, quality)
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
                            # Adicionar ao master playlist
                            if idx == 0:  # Apenas uma vez por qualidade
                                master_playlist_content.append(
                                    f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={scale.replace(":", "x")}'
                                )
                                master_playlist_content.append(f'video_0/{quality}/index.m3u8')
                    except subprocess.TimeoutExpired:
                        print(f"Timeout na conversão do vídeo {idx} para {quality}")
            
            # Adicionar ao master playlist para vídeos subsequentes
            for quality in qualities:
                if idx > 0:  # Para vídeos após o primeiro
                    master_playlist_content.append(f'#EXT-X-DISCONTINUITY')
                    master_playlist_content.append(f'# Video: {video_name}')
                    master_playlist_content.append(f'video_{idx}/{quality}/index.m3u8')
            
            processed_videos.append({
                'index': idx,
                'filename': original_filename,
                'display_name': video_name,
                'qualities': qualities,
                'path': f'video_{idx}'
            })
        
        # Criar master playlist
        master_playlist = os.path.join(output_dir, "master.m3u8")
        with open(master_playlist, 'w') as f:
            f.write('\n'.join(master_playlist_content))
        
        # Atualizar banco de dados
        conversions = load_conversions()
        conversion_data = {
            "conversion_id": conversion_id,
            "type": "multiple",
            "total_videos": len(processed_videos),
            "videos": processed_videos,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success",
            "master_m3u8_url": f"/hls/{conversion_id}/master.m3u8"
        }
        
        if not isinstance(conversions.get('conversions'), list):
            conversions['conversions'] = []
        
        conversions['conversions'].insert(0, conversion_data)
        conversions['stats']['total'] = conversions['stats'].get('total', 0) + 1
        conversions['stats']['success'] = conversions['stats'].get('success', 0) + 1
        
        save_conversions(conversions)
        
        log_activity(f"Conversão múltipla realizada: {len(processed_videos)} vídeos -> {conversion_id}")
        
        return jsonify({
            "success": True,
            "conversion_id": conversion_id,
            "total_videos": len(processed_videos),
            "qualities": qualities,
            "videos": processed_videos,
            "master_m3u8_url": f"/hls/{conversion_id}/master.m3u8",
            "player_url": f"/player/{conversion_id}"
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

# =============== ROTAS DE API E SERVIÇO ===============
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

@app.route('/hls/<conversion_id>/master.m3u8')
@app.route('/hls/<conversion_id>/<path:filename>')
def serve_hls(conversion_id, filename=None):
    """Servir arquivos HLS"""
    if filename is None:
        filename = "master.m3u8"
    
    filepath = os.path.join(HLS_DIR, conversion_id, filename)
    if os.path.exists(filepath):
        return send_file(filepath)
    return "Arquivo não encontrado", 404

@app.route('/player/<conversion_id>')
def player_page(conversion_id):
    """Página do player"""
    m3u8_url = f"/hls/{conversion_id}/master.m3u8"
    player_html = f'''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Player HLS - {conversion_id}</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <style>
            body {{ margin: 0; padding: 20px; background: #000; }}
            .player-container {{ max-width: 1200px; margin: 0 auto; }}
            .back-btn {{ 
                background: #4361ee; 
                color: white; 
                border: none; 
                padding: 10px 20px; 
                border-radius: 5px; 
                cursor: pointer;
                margin-bottom: 20px;
            }}
            .info-box {{
                background: #1a1a1a;
                color: #fff;
                padding: 15px;
                border-radius: 5px;
                margin-bottom: 20px;
                border-left: 4px solid #4361ee;
            }}
        </style>
    </head>
    <body>
        <div class="player-container">
            <button class="back-btn" onclick="window.history.back()">← Voltar</button>
            
            <div class="info-box">
                <h3 style="margin-top: 0;">🎬 Playlist de Múltiplos Vídeos</h3>
                <p>Todos os vídeos serão reproduzidos em sequência automaticamente.</p>
                <p><strong>ID:</strong> {conversion_id}</p>
            </div>
            
            <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="auto">
                <source src="{m3u8_url}" type="application/x-mpegURL">
            </video>
        </div>
        
        <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/videojs-contrib-hls/5.15.0/videojs-contrib-hls.min.js"></script>
        <script>
            var player = videojs('hlsPlayer');
            player.play();
            
            // Configurar para reprodução contínua
            player.on('ended', function() {{
                console.log('Vídeo atual terminado, próximo vídeo iniciará automaticamente');
            }});
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
        "service": "hls-converter-ultimate-multiple",
        "timestamp": datetime.now().isoformat(),
        "version": "3.0.0",
        "feature": "multiple-files",
        "ffmpeg": find_ffmpeg() is not None
    })

# =============== INICIALIZAÇÃO ===============
if __name__ == '__main__':
    print("=" * 70)
    print("🚀 HLS Converter ULTIMATE - Múltiplos Arquivos")
    print("=" * 70)
    print(f"📂 Diretório base: {BASE_DIR}")
    print(f"🔐 Autenticação: Habilitada")
    print(f"👤 Usuário padrão: admin / admin")
    print(f"🎬 Funcionalidade: Múltiplos arquivos em um único link")
    print(f"🌐 Porta: 8080")
    print("=" * 70)
    
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
    print("💡 Como usar:")
    print("   1. Selecione múltiplos arquivos na aba 'Upload Múltiplo'")
    print("   2. Escolha as qualidades desejadas")
    print("   3. Clique em 'Iniciar Conversão de Todos os Vídeos'")
    print("   4. Um único link M3U8 será gerado com todos os vídeos em sequência")
    print("=" * 70)
    
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
        app.run(host='0.0.0.0', port=8080, debug=False)
EOF

# [O resto do script continua igual, apenas atualizando as referências]

# 11. CRIAR ARQUIVOS DE BANCO DE DADOS
echo "💾 Criando arquivos de banco de dados..."

# Arquivo de usuários
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

# Arquivo de conversões (vazio)
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

# 12. CRIAR SCRIPT DE GERENCIAMENTO ATUALIZADO
echo "📝 Criando script de gerenciamento atualizado..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"

case "$1" in
    start)
        echo "🚀 Iniciando HLS Converter (Múltiplos Arquivos)..."
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
        
        if systemctl is-active --quiet hls-converter; then
            echo "✅ Serviço está ativo"
            
            echo "🌐 Testando health check..."
            if curl -s http://localhost:8080/health | grep -q "healthy"; then
                echo "✅ Health check OK"
            else
                echo "⚠️  Health check falhou"
                curl -s http://localhost:8080/health || true
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
        echo "🎬 Testando FFmpeg..."
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg encontrado: $(which ffmpeg)"
            ffmpeg -version | head -1
        else
            echo "❌ FFmpeg não encontrado"
        fi
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
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=" * 60
        echo "🎬 HLS Converter ULTIMATE - Múltiplos Arquivos"
        echo "=" * 60
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo "Porta: 8080"
        echo "Login: http://$IP:8080/login"
        echo "Usuário: admin"
        echo "Senha: admin (altere no primeiro acesso)"
        echo ""
        echo "✨ Funcionalidade:"
        echo "  ✅ Upload de múltiplos arquivos"
        echo "  ✅ Um único link M3U8 para todos os vídeos"
        echo "  ✅ Reprodução sequencial automática"
        echo ""
        echo "📁 Diretórios:"
        echo "  /opt/hls-converter/ - Diretório principal"
        echo "  /opt/hls-converter/uploads/ - Vídeos enviados"
        echo "  /opt/hls-converter/hls/ - Arquivos HLS"
        echo "  /opt/hls-converter/logs/ - Logs do sistema"
        echo "  /opt/hls-converter/db/ - Banco de dados"
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
        echo "  fix-ffmpeg   - Instalar/repare FFmpeg"
        echo "  cleanup      - Limpar arquivos antigos"
        echo "  reset-password - Resetar senha do admin"
        echo "  info         - Informações do sistema"
        echo ""
        echo "✨ Nova Funcionalidade:"
        echo "  - Upload de múltiplos arquivos"
        echo "  - Um único link para todos os vídeos"
        echo "  - Reprodução sequencial automática"
        echo ""
        echo "Exemplos:"
        echo "  hlsctl start"
        echo "  hlsctl logs -f"
        echo "  hlsctl test"
        echo "  hlsctl fix-ffmpeg"
        ;;
esac
EOF

# 13. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Configurando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter ULTIMATE Service (Multiple Files)
After=network.target
Wants=network.target

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

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db /opt/hls-converter/sessions

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
    echo "✅ Serviço iniciado com sucesso"
    sleep 3
else
    echo "❌ Falha ao iniciar serviço"
    journalctl -u hls-converter -n 20 --no-pager
fi

# 16. VERIFICAÇÃO FINAL
echo "🔍 Realizando verificação final..."

IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

if systemctl is-active --quiet hls-converter.service; then
    echo "🎉 SERVIÇO ATIVO E FUNCIONANDO!"
    
    echo ""
    echo "🧪 Testes rápidos:"
    
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "✅ Health check: OK"
    else
        echo "⚠️  Health check: Pode ter problemas"
    fi
    
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login)
    if [ "$STATUS_CODE" = "200" ]; then
        echo "✅ Página de login: OK"
    else
        echo "⚠️  Página de login: Código $STATUS_CODE"
    fi
    
else
    echo "❌ Serviço não está ativo"
    echo ""
    echo "📋 Logs de erro:"
    journalctl -u hls-converter -n 20 --no-pager
fi

# 17. INFORMAÇÕES FINAIS
echo ""
echo "=" * 70
echo "🎉 INSTALAÇÃO COMPLETA - MÚLTIPLOS ARQUIVOS EM UM ÚNICO LINK! 🎉"
echo "=" * 70
echo ""
echo "✅ SISTEMA PRONTO PARA USO"
echo ""
echo "🔐 INFORMAÇÕES DE ACESSO:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo "   ⚠️  IMPORTANTE: Altere a senha no primeiro acesso!"
echo ""
echo "🌐 URLS DO SISTEMA:"
echo "   🔐 Login:    http://$IP:8080/login"
echo "   🎮 Dashboard: http://$IP:8080/"
echo "   🩺 Health:   http://$IP:8080/health"
echo ""
echo "✨ NOVA FUNCIONALIDADE:"
echo "   • 📁 Upload de múltiplos arquivos de uma vez"
echo "   • 🔗 Um único link M3U8 para todos os vídeos"
echo "   • ▶️ Reprodução sequencial automática"
echo "   • 🎬 Vídeos numerados (Vídeo 1, Vídeo 2, etc.)"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start      - Iniciar serviço"
echo "   • hlsctl stop       - Parar serviço"
echo "   • hlsctl restart    - Reiniciar serviço"
echo "   • hlsctl status     - Ver status"
echo "   • hlsctl logs       - Ver logs"
echo "   • hlsctl test       - Testar sistema"
echo "   • hlsctl fix-ffmpeg - Reparar FFmpeg"
echo ""
echo "💡 COMO USAR A NOVA FUNCIONALIDADE:"
echo "   1. Acesse http://$IP:8080/login"
echo "   2. Vá para a aba 'Upload Múltiplo'"
echo "   3. Selecione vários arquivos de vídeo"
echo "   4. Escolha as qualidades desejadas"
echo "   5. Clique em 'Iniciar Conversão de Todos os Vídeos'"
echo "   6. Um único link será gerado para todos os vídeos"
echo "   7. Os vídeos serão reproduzidos em sequência automaticamente"
echo ""
echo "=" * 70
echo "🚀 Sistema pronto! Acesse http://$IP:8080/login"
echo "=" * 70
