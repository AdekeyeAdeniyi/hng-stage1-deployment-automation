# Simple Nginx Static Site (Docker)

Static HTML/CSS site served by nginx inside Docker.

Prerequisites
- Docker
- (Optional) Docker Compose

Project layout
- public/         - contains index.html and styles.css (static site)
- Dockerfile      - builds nginx image copying public/ into nginx html folder
- docker-compose.yml - service definition for running the container

Quick start (using docker-compose)
1. Open a terminal and change directory:
   cd "c:\Users\PC\Documents\HNG Internship\DevOps\Stage1"
2. Build and run:
   docker-compose up --build
3. Open: http://localhost:8080
4. Stop:
   docker-compose down

Quick start (docker CLI)
1. Build:
   docker build -t simple-nginx .
2. Run:
   docker run -p 8080:80 --rm simple-nginx
3. Open: http://localhost:8080

Notes
- Edit files in public/ to change the served site. Rebuild the image after changes when using the image build method, or mount the folder as a volume for rapid development.
- To mount the host public folder (for development):
  docker run -p 8080:80 -v "%CD%/public:/usr/share/nginx/html:ro" --rm simple-nginx

License
This project is licensed under the MIT License. See LICENSE file.