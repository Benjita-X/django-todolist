# django-todolist

API REST de tareas (ToDoList) hecha con **Django + Django REST Framework**, desplegada en una instancia **EC2 de AWS** (Ubuntu 22.04) con **Gunicorn** como servidor WSGI y **Nginx** como proxy inverso.

```
Navegador ──HTTP:80──> Nginx ──socket unix──> Gunicorn (3 workers) ──> Django + DRF ──> SQLite
                        │
                        └── /static/  (CSS/JS servidos directo por Nginx)
```

## Estructura

```
django-todolist/
├── manage.py
├── requirements.txt
├── todolist_project/        # proyecto Django (settings, urls, wsgi)
├── tasks/                   # app: modelo Task, serializer, viewset
│   ├── models.py
│   ├── serializers.py
│   ├── views.py
│   └── migrations/0001_initial.py
└── deploy/
    ├── desplegar.sh         # ejecuta las ETAPAS 3 a 8 de la receta dentro del EC2
    ├── gunicorn.service     # /etc/systemd/system/gunicorn.service
    └── nginx_todolist       # /etc/nginx/sites-available/todolist
```

## Endpoints

| Método | URL | Qué hace |
|---|---|---|
| GET | `/api/` | Raíz navegable de DRF |
| GET | `/api/tasks/` | Lista las tareas |
| POST | `/api/tasks/` | Crea una tarea `{"title": "...", "done": false}` |
| GET / PUT / PATCH / DELETE | `/api/tasks/<id>/` | Ver, editar o borrar una tarea |
| — | `/admin/` | Admin de Django |

## Correr en local (Windows)

```powershell
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver
```

Abrir http://127.0.0.1:8000/api/tasks/

> Gunicorn no corre en Windows; en local se usa `runserver`. Gunicorn + Nginx van en el servidor Ubuntu.

## Despliegue en EC2 (resumen de la receta)

1. **ETAPA 1** – EC2 `django-todolist`, Ubuntu 22.04, t2.micro, key pair `claves.pem`, VPC por defecto con IP pública, Security Group (22 desde mi IP, 80, 443, ICMP) e **IP elástica**.
2. **ETAPA 2** – `ssh -i "claves.pem" ubuntu@<IP_ELASTICA>`
3. **ETAPAS 3–8** – copiar y ejecutar el script:
   ```bash
   scp -i claves.pem deploy/desplegar.sh ubuntu@<IP_ELASTICA>:~
   ssh -i claves.pem ubuntu@<IP_ELASTICA> "bash desplegar.sh"
   ```
4. Probar: `http://<IP_ELASTICA>/api/tasks/` y `http://<IP_ELASTICA>/admin/`

### Dos ajustes necesarios respecto a la receta
- `python manage.py makemigrations tasks` antes de `migrate`: sin esto la tabla `tasks_task` no existe y `/api/tasks/` falla con *no such table*.
- `sudo rm /etc/nginx/sites-enabled/default`: el sitio por defecto de Nginx es `default_server` en el puerto 80 y tapa al nuestro (sale "Welcome to nginx").
