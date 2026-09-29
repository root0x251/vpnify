# Информация по настройке VPS

## Запуск скрипта на VPS

 Быстрый запуск без сохранения скрипта на сервере
```bash
curl -fsSL https://raw.githubusercontent.com/root0x251/vpnify/refs/heads/main/setup.sh | bash
```

Быстрый запуск с сохранением скрипта на сервере
```bash 
curl -fsSL https://raw.githubusercontent.com/root0x251/vpnify/refs/heads/main/setup.sh -o setup.sh \
&& chmod +x setup.sh && bash setup.sh 
```

Скрипт запускается под пользователем  root. Имеется возможность полной  или частичной установки.

## Как работает скрипт

Скрипт по шагам подготавливает VPS и разворачивает сервисы:

1. Этап 0 — сбор данных: домены, IP, порты, email, секреты, подтверждение параметров.
2. Этап 1 — создание пользователя, SSH, swap, UFW, Fail2Ban.
3. Этап 2 — Docker, папки, сеть proxy-net.
4. Этап 3 — Nginx Proxy Manager.
5. Этап 4 — сайт-заглушка.
6. Этап 5 — 3x-ui.
7. Этап 6 — Hysteria2.
8. Этап 7 — Telemt MTProxy.

Важные этапы 0-5, опциональные этапы 6, 7

В режиме полная установка происходит установка всех этапов.
В режиме selective выбираются только нужные пункты. Скрипт сохраняет состояние и умеет продолжить с нужного этапа после перезапуска.

## Что где хранится и что делать после установки

### Файлы состояния и логов

- `/root/.vps-setup-state` — текущее состояние этапов, чтобы можно было продолжить установку.
- `/root/.vps-setup-vars` — сохраненные параметры: домены, порты, IP, секреты.
- `/var/log/vps-setup.log` — полный лог установки и ошибок.
- `/root/vps-setup-summary.txt` — итоговая сводка с адресами, логинами и ссылками.

### Docker и конфиги

Все контейнеры и их данные хранятся в `/opt/docker/`:

- `/opt/docker/nginx-proxy-manager/` — NPM
- `/opt/docker/nginx-site/` — заглушка сайта
- `/opt/docker/3x-ui/` — панель 3x-ui
- `/opt/docker/hysteria2/` — Hysteria2
- `/opt/docker/telemt/` — Telemt

### Что следует удалить после сохранения данных

После того как ты сохранишь нужные пароли/ссылки:

```bash
rm /root/vps-setup-summary.txt
```

```bash
rm /root/.vps-setup-vars
```

Предварительно стоит ознакомиться\сохранить важную информацию

### Как управлять установкой

- Для повторного запуска отдельных этапов: запускай скрипт заново и выбери `Перезапустить отдельные этапы`.
- Для полного отката: в меню выбери `Полный откат системы`.
- Для обновления контейнеров:

```bash
cd /opt/docker/nginx-proxy-manager && docker compose pull && docker compose up -d
```

```bash
cd /opt/docker/3x-ui && docker compose pull && docker compose up -d
```

```bash
cd /opt/docker/hysteria2 && docker compose pull && docker compose up -d
```

```bash
cd /opt/docker/telemt && docker compose pull && docker compose up -d
```

Важно: контейнеры хранятся в `/opt/docker`, там лежат конфиги, сертификаты. Полный откат удаляет все это только после подтверждения.