#!/bin/bash
# uninstall_hls_converter.sh - Remove completamente o HLS Converter

set -e

echo "🗑️  DESINSTALANDO HLS CONVERTER ULTIMATE v2.4.0"
echo "=================================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./uninstall_hls_converter.sh"
    exit 1
fi

# 2. Confirmar desinstalação
echo ""
echo "⚠️  ⚠️  ⚠️  ATENÇÃO ⚠️  ⚠️  ⚠️"
echo "Esta ação irá remover COMPLETAMENTE o HLS Converter ULTIMATE."
echo "Isso inclui:"
echo "  • Todos os vídeos convertidos"
echo "  • Histórico de conversões"
echo "  • Usuários e configurações"
echo "  • Backups"
echo "  • Arquivos temporários"
echo ""
read -p "Tem certeza que deseja continuar? (s/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "✅ Desinstalação cancelada."
    exit 0
fi

echo ""
echo "🛑 Parando serviços..."

# 3. Parar e desabilitar serviços
if systemctl is-active --quiet hls-converter.service; then
    systemctl stop hls-converter.service
    echo "✅ Serviço hls-converter parado"
fi

if systemctl is-enabled --quiet hls-converter.service; then
    systemctl disable hls-converter.service
    echo "✅ Serviço hls-converter desabilitado"
fi

# 4. Remover serviço systemd
if [ -f /etc/systemd/system/hls-converter.service ]; then
    rm -f /etc/systemd/system/hls-converter.service
    echo "✅ Arquivo de serviço systemd removido"
fi

systemctl daemon-reload
echo "✅ Systemd recarregado"

# 5. Remover configuração nginx
if [ -f /etc/nginx/sites-available/hls-converter ]; then
    rm -f /etc/nginx/sites-available/hls-converter
    echo "✅ Configuração nginx removida"
fi

if [ -L /etc/nginx/sites-enabled/hls-converter ]; then
    rm -f /etc/nginx/sites-enabled/hls-converter
    echo "✅ Link nginx removido"
fi

# Restaurar site default se necessário
if [ ! -f /etc/nginx/sites-enabled/default ] && [ -f /etc/nginx/sites-available/default ]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
    echo "✅ Site default restaurado"
fi

systemctl restart nginx
echo "✅ Nginx reiniciado"

# 6. Remover script de gerenciamento
if [ -f /usr/local/bin/hlsctl ]; then
    rm -f /usr/local/bin/hlsctl
    echo "✅ Script hlsctl removido"
fi

# 7. Backup opcional dos dados
echo ""
read -p "Deseja fazer backup dos dados antes de remover? (s/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    BACKUP_DIR="/tmp/hls_converter_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo "📦 Criando backup em: $BACKUP_DIR"
    
    # Backup dos arquivos importantes
    if [ -d "/opt/hls-converter" ]; then
        # Backup do banco de dados
        if [ -d "/opt/hls-converter/db" ]; then
            cp -r /opt/hls-converter/db "$BACKUP_DIR/"
            echo "✅ Banco de dados salvo"
        fi
        
        # Backup dos backups existentes
        if [ -d "/opt/hls-converter/backups" ]; then
            cp -r /opt/hls-converter/backups "$BACKUP_DIR/"
            echo "✅ Backups salvos"
        fi
        
        # Backup dos vídeos internos
        if [ -d "/opt/hls-converter/internal_media" ]; then
            cp -r /opt/hls-converter/internal_media "$BACKUP_DIR/"
            echo "✅ Vídeos internos salvos"
        fi
        
        # Backup dos logs
        if [ -d "/opt/hls-converter/logs" ]; then
            cp -r /opt/hls-converter/logs "$BACKUP_DIR/"
            echo "✅ Logs salvos"
        fi
        
        # Backup das conversões HLS
        if [ -d "/opt/hls-converter/hls" ]; then
            echo "⚠️  Diretório HLS é grande. Backup parcial..."
            find /opt/hls-converter/hls -maxdepth 2 -type d | head -20 > "$BACKUP_DIR/hls_directories.txt"
        fi
        
        echo ""
        echo "📊 Tamanho do backup:"
        du -sh "$BACKUP_DIR"
        echo ""
        echo "📁 Local do backup: $BACKUP_DIR"
        echo "💾 Para restaurar: sudo cp -r $BACKUP_DIR/* /opt/hls-converter/"
    fi
fi

# 8. Remover diretórios principais
echo ""
echo "🧹 Removendo arquivos..."

if [ -d "/opt/hls-converter" ]; then
    echo "📁 Removendo /opt/hls-converter..."
    
    # Listar tamanho antes de remover
    echo "📊 Tamanho do diretório:"
    du -sh /opt/hls-converter
    
    # Confirmar remoção de dados grandes
    HLS_SIZE=$(du -s /opt/hls-converter/hls 2>/dev/null | cut -f1 2>/dev/null || echo "0")
    if [ "$HLS_SIZE" -gt 1000000 ]; then  # Mais de 1GB
        echo ""
        echo "⚠️  ATENÇÃO: Diretório HLS contém mais de 1GB de dados!"
        read -p "Deseja remover TODOS os vídeos convertidos? (s/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            echo "📁 Mantendo diretório HLS..."
            # Mover apenas outros diretórios
            mv /opt/hls-converter /opt/hls-converter_old_$(date +%Y%m%d_%H%M%S)
            mkdir -p /opt/hls-converter
            mv /opt/hls-converter_old_*/hls /opt/hls-converter/ 2>/dev/null || true
            rm -rf /opt/hls-converter_old_*
            echo "✅ Apenas arquivos de sistema removidos"
        else
            rm -rf /opt/hls-converter
            echo "✅ Diretório completo removido"
        fi
    else
        rm -rf /opt/hls-converter
        echo "✅ Diretório completo removido"
    fi
else
    echo "ℹ️  Diretório /opt/hls-converter não encontrado"
fi

# 9. Remover usuário (opcional)
echo ""
read -p "Deseja remover o usuário 'hlsuser'? (s/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    if id "hlsuser" &>/dev/null; then
        # Verificar se o usuário está em uso
        if ! ps -u hlsuser > /dev/null 2>&1; then
            userdel -r hlsuser 2>/dev/null || userdel hlsuser
            echo "✅ Usuário hlsuser removido"
        else
            echo "⚠️  Usuário hlsuser ainda em uso. Não removido."
        fi
    else
        echo "ℹ️  Usuário hlsuser não encontrado"
    fi
fi

# 10. Remover dependências (opcional)
echo ""
read -p "Deseja remover as dependências instaladas? (s/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Ss]$ ]]; then
    echo "📦 Removendo dependências..."
    
    # Remover pacotes Python específicos
    if [ -d "/opt/hls-converter/venv" ]; then
        /opt/hls-converter/venv/bin/pip freeze > /tmp/hls_packages.txt 2>/dev/null || true
    fi
    
    # Remover pacotes do sistema (cuidado!)
    echo "⚠️  As seguintes dependências serão mantidas:"
    echo "   • python3, python3-pip (necessários para outros programas)"
    echo "   • nginx (pode ser usado por outros sites)"
    echo "   • ffmpeg (útil para outras aplicações)"
    echo ""
    read -p "Remover ffmpeg? (s/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        apt-get remove -y ffmpeg 2>/dev/null || true
        echo "✅ FFmpeg removido"
    fi
    
    read -p "Remover pacotes Python específicos? (s/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        apt-get remove -y python3-venv python3-pip 2>/dev/null || true
        echo "✅ Pacotes Python removidos"
    fi
fi

# 11. Limpar arquivos temporários
echo ""
echo "🧽 Limpando arquivos temporários..."
rm -rf /tmp/hls_* /var/tmp/hls_* 2>/dev/null || true
echo "✅ Arquivos temporários limpos"

# 12. Limpar logs do systemd
echo ""
echo "📋 Limpando logs..."
journalctl --vacuum-time=1d 2>/dev/null || true
echo "✅ Logs limpos"

# 13. Verificar remoção
echo ""
echo "🔍 Verificando remoção..."
echo ""

REMOVED=1

if [ -d "/opt/hls-converter" ]; then
    echo "❌ /opt/hls-converter ainda existe"
    REMOVED=0
else
    echo "✅ /opt/hls-converter removido"
fi

if systemctl is-active --quiet hls-converter.service; then
    echo "❌ Serviço ainda está ativo"
    REMOVED=0
else
    echo "✅ Serviço parado"
fi

if [ -f "/etc/systemd/system/hls-converter.service" ]; then
    echo "❌ Arquivo de serviço ainda existe"
    REMOVED=0
else
    echo "✅ Arquivo de serviço removido"
fi

if [ -f "/usr/local/bin/hlsctl" ]; then
    echo "❌ Script hlsctl ainda existe"
    REMOVED=0
else
    echo "✅ Script hlsctl removido"
fi

echo ""
echo "=" * 70
if [ $REMOVED -eq 1 ]; then
    echo "🎉 DESINSTALAÇÃO COMPLETA COM SUCESSO!"
else
    echo "⚠️  Desinstalação parcial. Alguns itens podem precisar de remoção manual."
    echo ""
    echo "Para remoção manual completa:"
    echo "1. sudo rm -rf /opt/hls-converter"
    echo "2. sudo rm -f /etc/systemd/system/hls-converter.service"
    echo "3. sudo rm -f /usr/local/bin/hlsctl"
    echo "4. sudo systemctl daemon-reload"
fi
echo "=" * 70

# 14. Sugerir reinstalação
echo ""
echo "🔄 Para reinstalar:"
echo "   sudo ./install_hls_converter_final_corrigido.sh"
echo ""
echo "👋 Desinstalação concluída!"
