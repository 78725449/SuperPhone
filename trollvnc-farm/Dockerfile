FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY server ./server
COPY web ./web
ENV NODE_ENV=production
ENV FARM_PORT=8080
EXPOSE 8080
CMD ["node", "server/index.js"]
