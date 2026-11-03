# Guía de estudio – EC2 + Gunicorn + Nginx para DRF

Lo que tienes que saber explicar mientras muestras el proyecto funcionando.

---

## 1. La idea en una frase

> "Desplegué una API REST de tareas hecha en Django REST Framework en un servidor Ubuntu en AWS EC2. **Nginx** recibe las peticiones en el puerto 80 y se las pasa por un **socket** a **Gunicorn**, que ejecuta Django. Nginx además sirve directo los archivos estáticos."

```
Cliente (navegador)
   │  http://IP_ELASTICA/api/tasks/   (puerto 80)
   ▼
[ Security Group ]  ← firewall de AWS: deja pasar 22, 80, 443, ICMP
   ▼
[ Nginx ]  usuario www-data
   │  /static/ → lo sirve él mismo desde /home/ubuntu/apps/static/
   │  /        → proxy_pass a unix:/home/ubuntu/apps/todolist.sock
   ▼
[ Gunicorn ]  usuario ubuntu, 3 workers, servicio systemd
   ▼
[ Django + DRF ] → TaskViewSet → Task (SQLite)
```

### ¿Por qué tres piezas y no solo `runserver`?
| Pieza | Rol | Por qué |
|---|---|---|
| `runserver` | Servidor de **desarrollo** | Un solo proceso, inseguro, lento. Solo para probar (ETAPA 4.9). |
| **Gunicorn** | Servidor **WSGI** de producción | Traduce HTTP ↔ Python (WSGI) y levanta varios *workers* para atender en paralelo. |
| **Nginx** | **Proxy inverso** / servidor web | Da la cara a Internet en el puerto 80, sirve estáticos rápido, maneja muchas conexiones, guarda logs, y deja la puerta lista para HTTPS. |

**Proxy inverso** = un servidor que recibe las peticiones del cliente *en nombre* de otro servidor (Gunicorn) y se las reenvía. El cliente nunca habla directo con Gunicorn.

---

## 2. Etapa por etapa (qué hace y por qué)

### ETAPA 1 – Infraestructura en AWS
- **EC2**: máquina virtual en la nube. AMI = imagen del sistema (Ubuntu Server 22.04 LTS). `t2.micro` / `t3.micro` = 1 GB RAM, capa gratuita.
- **Key Pair (`claves.pem`)**: clave privada para entrar por SSH. AWS guarda la pública en la instancia. **No se puede volver a descargar**: si la pierdes, no entras.
- **VPC por defecto**: la red privada virtual de tu cuenta. Ya trae subred pública e Internet Gateway, por eso no hay que crear una.
- **IP pública automática**: para que la instancia sea alcanzable desde Internet.
- **Security Group**: firewall a nivel de instancia (stateful).
  - 22 SSH → *desde tu IP* (solo tú administras).
  - 80 HTTP → desde `0.0.0.0/0` (todo el mundo ve la API).
  - 443 HTTPS → opcional, para SSL futuro.
  - ICMP → para poder hacer `ping`.
- **IP elástica (EIP)**: IP pública **fija**. La IP pública normal cambia cada vez que detienes/inicias la instancia; la elástica no.

### ETAPA 2 – Conexión desde Windows
```powershell
ssh -i "claves.pem" ubuntu@<IP_ELASTICA>
```
- `ubuntu` es el usuario por defecto de las AMIs de Ubuntu.
- SSH rechaza claves con permisos "abiertos" (*UNPROTECTED PRIVATE KEY FILE*). En Windows se arregla con `icacls` (quitar herencia y dejar solo lectura a tu usuario); en Linux con `chmod 400`.

### ETAPA 3 – Preparar Ubuntu
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3-pip python3-venv nginx git -y
```
`update` refresca la lista de paquetes, `upgrade` los actualiza. Se instala pip, venv, Nginx y git.

### ETAPA 4 – Proyecto Django + DRF
| Paso | Comando / archivo | Para qué |
|---|---|---|
| venv | `python3 -m venv venv` + `source venv/bin/activate` | Aislar las librerías del proyecto de las del sistema |
| librerías | `pip install django djangorestframework gunicorn` | |
| proyecto | `django-admin startproject todolist_project .` | El `.` lo crea en la carpeta actual (`~/apps`) |
| app | `python manage.py startapp tasks` | |
| settings | `ALLOWED_HOSTS = ['*']`, `'rest_framework'`, `'tasks'` | Aceptar cualquier host (la IP) y registrar DRF y la app |
| modelo | `Task(title, done)` | Tabla en la BD |
| serializer | `TaskSerializer(ModelSerializer)` | Convierte `Task` ⇄ JSON y valida |
| vista | `TaskViewSet(ModelViewSet)` | CRUD completo: list, create, retrieve, update, partial_update, destroy |
| rutas | `DefaultRouter` + `router.register('tasks', ...)` | Genera `/api/tasks/` y `/api/tasks/<id>/` automáticamente |
| BD | `makemigrations tasks` + `migrate` | Crear las tablas |
| prueba | `runserver 0.0.0.0:8000` | `0.0.0.0` = escuchar en todas las interfaces, no solo localhost |

### ETAPA 5 – Gunicorn como servicio systemd
Archivo `/etc/systemd/system/gunicorn.service`:
- `User=ubuntu` / `Group=www-data` → corre como ubuntu, pero el socket queda del grupo de Nginx.
- `WorkingDirectory=/home/ubuntu/apps` → donde está `manage.py`.
- `--workers 3` → 3 procesos (regla típica: 2 × núcleos + 1).
- `--bind unix:/home/ubuntu/apps/todolist.sock` → en vez de un puerto TCP, un **socket Unix** (archivo especial para comunicar procesos en la misma máquina; más rápido y no queda expuesto a la red).
- `todolist_project.wsgi:application` → el punto de entrada WSGI de Django.
- `WantedBy=multi-user.target` + `systemctl enable` → arranca solo al reiniciar el servidor.

### ETAPA 6 – Nginx como proxy inverso
Archivo `/etc/nginx/sites-available/todolist`, activado con un enlace en `sites-enabled`:
- `listen 80; server_name _;` → escucha en el 80 para cualquier nombre.
- `location /static/ { alias ...; }` → los CSS/JS los entrega Nginx directo.
- `location / { include proxy_params; proxy_pass http://unix:...todolist.sock; }` → todo lo demás va a Gunicorn. `proxy_params` agrega las cabeceras `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
- `nginx -t` → valida sintaxis antes de reiniciar.
- Se borra `sites-enabled/default`, porque ese sitio también escucha en el 80 como `default_server` y taparía el nuestro.

### Permisos (la parte que más falla)
Nginx corre como **www-data** y necesita llegar al socket que crea **ubuntu**:
```
/home/ubuntu              drwxr-x---  ubuntu ubuntu     ← www-data entra porque está en el grupo ubuntu
/home/ubuntu/apps         drwxrwx---  ubuntu www-data
/home/ubuntu/apps/todolist.sock  srw-rw----  ubuntu www-data
```
Comandos clave: `usermod -aG`, `chmod 750/770/660`, `chown ubuntu:www-data`, y para revisar `namei -l ruta`.

### Estáticos
- `STATIC_ROOT = '/home/ubuntu/apps/static/'` + `python manage.py collectstatic` → junta el CSS/JS de admin y DRF en una carpeta.
- Sin esto `/admin/` y `/api/` se ven "sin diseño", porque Gunicorn no sirve estáticos cuando no es modo desarrollo.

### ETAPA 8 – Reinicio y prueba
```bash
sudo systemctl daemon-reload      # relee los .service
sudo systemctl restart gunicorn
sudo systemctl restart nginx
sudo systemctl status gunicorn    # debe decir active (running)
sudo systemctl status nginx
```

---

## 3. Errores típicos (tabla de la receta)

| Error | Causa | Solución |
|---|---|---|
| **502 Bad Gateway** | Nginx no logra hablar con Gunicorn (socket no existe) | `systemctl status gunicorn`, revisar el `.service`, reiniciar |
| **(13) Permission denied** en el log de Nginx | www-data no puede entrar a la carpeta o al socket | Permisos de la sección anterior |
| **(2) No such file** | Ruta del socket mal escrita en `proxy_pass` | Igualar la ruta en Nginx y en Gunicorn |
| **(111) Connection refused** | Gunicorn no está corriendo | `systemctl restart gunicorn` |
| Gunicorn no inicia | Ruta del venv o del módulo wsgi mal | Corregir `ExecStart` y `WorkingDirectory` |
| "Welcome to nginx" | El sitio `default` sigue activo | `sudo rm /etc/nginx/sites-enabled/default` |
| `no such table: tasks_task` | Faltó `makemigrations` | `makemigrations tasks` + `migrate` |
| Admin sin estilos | Faltó `collectstatic` o el `location /static/` | Sección de estáticos |
| SSH: *UNPROTECTED PRIVATE KEY FILE* | Permisos de `claves.pem` muy abiertos | `icacls ... /inheritance:r` y `/grant:r "%username%:R"` |
| SSH: timeout | Puerto 22 no permitido desde tu IP (cambió tu IP) | Editar el Security Group |

Logs para mirar: `sudo tail -n 20 /var/log/nginx/todolist_error.log` y `sudo journalctl -u gunicorn -n 30`.

---

## 4. Guion para la demo en vivo (5 min)

1. **AWS**: mostrar la instancia `django-todolist` *running*, su IP elástica y el Security Group (22, 80, 443, ICMP).
2. **Ping**: `ping <IP_ELASTICA>` → responde gracias a la regla ICMP.
3. **SSH**: `ssh -i "C:\AWS_KEYS\claves.pem" ubuntu@<IP_ELASTICA>`
4. **Servicios**:
   ```bash
   sudo systemctl status gunicorn --no-pager
   sudo systemctl status nginx --no-pager
   ls -l /home/ubuntu/apps/todolist.sock
   cat /etc/nginx/sites-available/todolist
   ```
5. **Navegador**: `http://<IP_ELASTICA>/api/tasks/` → crear una tarea desde el formulario de DRF (POST), luego verla en la lista.
6. **Admin**: `http://<IP_ELASTICA>/admin/` → se ve con estilos (estáticos servidos por Nginx).
7. **Prueba de que Nginx manda**: `curl -I http://localhost/api/` dentro del servidor → `Server: nginx`.
8. **GitHub**: mostrar el repo y la carpeta `deploy/`.

---

## 5. Preguntas que te puede hacer el profe

1. **¿Qué diferencia hay entre Nginx y Gunicorn?** Nginx es servidor web/proxy inverso (red, estáticos, conexiones); Gunicorn es servidor de aplicaciones WSGI que ejecuta el código Python.
2. **¿Qué es WSGI?** El estándar que define cómo un servidor web habla con una app Python (`todolist_project/wsgi.py` expone `application`).
3. **¿Por qué socket Unix y no puerto 8000?** Más rápido, y Gunicorn no queda expuesto a Internet: solo Nginx puede hablarle.
4. **¿Qué pasa si reinicio la instancia?** Gunicorn y Nginx arrancan solos (`systemctl enable`) y la IP no cambia (IP elástica).
5. **¿Por qué SSH solo desde mi IP?** Para que nadie más pueda intentar entrar al servidor.
6. **¿Qué hace `ALLOWED_HOSTS = ['*']`?** Acepta peticiones a cualquier host/IP. En producción real se pone solo la IP o el dominio.
7. **¿Qué es un ViewSet / Router?** El ViewSet agrupa todas las acciones CRUD en una clase; el Router genera las URLs automáticamente.
8. **¿Para qué el venv?** Aislar versiones de librerías del proyecto.
9. **¿Qué es `www-data`?** El usuario con el que corre Nginx en Ubuntu.
10. **¿Qué faltaría para producción real?** `DEBUG = False`, `SECRET_KEY` fuera del código, HTTPS (Certbot en el 443), base de datos como PostgreSQL/RDS, `ALLOWED_HOSTS` restringido.

---

## 6. Practicar en tu PC (sin AWS)

```powershell
cd django-todolist
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver
```
- http://127.0.0.1:8000/api/tasks/ → crea, edita y borra tareas desde la interfaz de DRF.
- `python manage.py createsuperuser` → luego entra a http://127.0.0.1:8000/admin/

(En local el CSS sale gracias a `runserver` con `DEBUG = True`; en el servidor lo sirve Nginx.)
