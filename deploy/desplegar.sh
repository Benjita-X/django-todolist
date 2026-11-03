#!/bin/bash
# Receta AWS - EC2 + Gunicorn + Nginx para DRF (ETAPAS 3 a 8)
# Se ejecuta DENTRO de la instancia Ubuntu 22.04 como usuario ubuntu:  bash desplegar.sh
set -e
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a   # evita los menús interactivos de apt

echo "===== ETAPA 3: Configurar el servidor Ubuntu ====="
sudo -E apt update && sudo -E apt upgrade -y
sudo -E apt install python3-pip python3-venv nginx git -y

echo "===== ETAPA 4: Crear el proyecto Django + DRF (ToDoList) ====="
# 1. Entorno virtual
mkdir -p ~/apps && cd ~/apps
python3 -m venv venv
source venv/bin/activate
# 2. Django + DRF
pip install django djangorestframework gunicorn
# 3. Proyecto
django-admin startproject todolist_project .
# 4. App
python manage.py startapp tasks

# 5. settings.py: ALLOWED_HOSTS y INSTALLED_APPS
SETTINGS=todolist_project/settings.py
sed -i "s/^ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" $SETTINGS
sed -i "s/    'django.contrib.staticfiles',/    'django.contrib.staticfiles',\n    'rest_framework',\n    'tasks',/" $SETTINGS

# 6. Modelo
cat > tasks/models.py <<'EOF'
from django.db import models

class Task(models.Model):
    title = models.CharField(max_length=200)
    done = models.BooleanField(default=False)

    def __str__(self):
        return self.title
EOF

# 7. Serializer y vista
cat > tasks/serializers.py <<'EOF'
from rest_framework import serializers
from .models import Task

class TaskSerializer(serializers.ModelSerializer):
    class Meta:
        model = Task
        fields = '__all__'
EOF

cat > tasks/views.py <<'EOF'
from rest_framework import viewsets
from .models import Task
from .serializers import TaskSerializer

class TaskViewSet(viewsets.ModelViewSet):
    queryset = Task.objects.all()
    serializer_class = TaskSerializer
EOF

# 8. Rutas
cat > todolist_project/urls.py <<'EOF'
from django.contrib import admin
from django.urls import path, include
from rest_framework import routers
from tasks.views import TaskViewSet

router = routers.DefaultRouter()
router.register(r'tasks', TaskViewSet)

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include(router.urls)),
]
EOF

# 9. Migrar (makemigrations es necesario para que exista la tabla de Task)
python manage.py makemigrations tasks
python manage.py migrate
# (La prueba con runserver 0.0.0.0:8000 se hace a mano; aquí se valida con check)
python manage.py check

echo "===== ETAPA 5: Configurar Gunicorn ====="
sudo tee /etc/systemd/system/gunicorn.service > /dev/null <<'EOF'
[Unit]
Description=Gunicorn daemon for Django ToDoList
After=network.target

[Service]
User=ubuntu
Group=www-data
WorkingDirectory=/home/ubuntu/apps
ExecStart=/home/ubuntu/apps/venv/bin/gunicorn --workers 3 --bind unix:/home/ubuntu/apps/todolist.sock todolist_project.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl start gunicorn
sudo systemctl enable gunicorn

echo "===== ETAPA 6: Configurar Nginx como proxy inverso ====="
sudo tee /etc/nginx/sites-available/todolist > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://unix:/home/ubuntu/apps/todolist.sock;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    error_log /var/log/nginx/todolist_error.log;

    access_log /var/log/nginx/todolist_access.log;
}
EOF
sudo ln -sf /etc/nginx/sites-available/todolist /etc/nginx/sites-enabled
# El sitio "default" de Nginx también escucha en el 80 y gana; se desactiva para que responda el nuestro
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

echo "===== Solución A (permisos socket / www-data) ====="
sudo usermod -aG www-data ubuntu
sudo usermod -aG ubuntu www-data
sudo chmod 750 /home/ubuntu
sudo chmod 770 /home/ubuntu/apps
sudo chown ubuntu:www-data /home/ubuntu/apps
sudo systemctl restart gunicorn
sleep 2
sudo chown ubuntu:www-data /home/ubuntu/apps/todolist.sock
sudo chmod 660 /home/ubuntu/apps/todolist.sock
sudo systemctl restart nginx

echo "===== Archivos estáticos (STATIC_ROOT) ====="
cat >> $SETTINGS <<'EOF'

STATIC_URL = '/static/'
STATIC_ROOT = '/home/ubuntu/apps/static/'
EOF
python manage.py collectstatic --noinput
ls /home/ubuntu/apps/static/

sudo tee /etc/nginx/sites-available/todolist > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    location /static/ {
        alias /home/ubuntu/apps/static/;
    }
    location / {
        include proxy_params;
        proxy_pass http://unix:/home/ubuntu/apps/todolist.sock;
    }
    error_log /var/log/nginx/todolist_error.log;
    access_log /var/log/nginx/todolist_access.log;
}
EOF
sudo nginx -t
sudo chown -R ubuntu:www-data /home/ubuntu/apps/static
sudo chmod -R 755 /home/ubuntu/apps/static

echo "===== ETAPA 8: Probar y finalizar ====="
sudo systemctl daemon-reload
sudo systemctl restart gunicorn
sudo systemctl restart nginx
sleep 2
sudo systemctl status gunicorn --no-pager | head -n 5
sudo systemctl status nginx --no-pager | head -n 5

echo "===== Validación ====="
ls -ld /home /home/ubuntu /home/ubuntu/apps /home/ubuntu/apps/todolist.sock
namei -l /home/ubuntu/apps/todolist.sock
curl -s --unix-socket /home/ubuntu/apps/todolist.sock http://localhost/api/ ; echo
curl -sI http://localhost/api/tasks/ | head -n 2
curl -sI http://localhost/static/rest_framework/css/bootstrap.min.css | head -n 1
echo "LISTO -> http://<IP_ELASTICA>/api/tasks/"
