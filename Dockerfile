FROM nginx:alpine
LABEL maintainer="HNG Internship"

# clean default nginx html and copy your static site
RUN rm -rf /usr/share/nginx/html/*
COPY public/ /usr/share/nginx/html/

# ensure readable permissions
RUN chmod -R 755 /usr/share/nginx/html

EXPOSE 80

# simple healthcheck (uses wget from busybox)
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- --spider http://localhost:80 || exit 1

# keep default nginx entrypoint/command
# CMD ["nginx", "-g", "daemon off;"]