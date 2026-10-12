FROM nginx:1.27-alpine

# Replace the default site config with one that also proxies /api to the api service
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
