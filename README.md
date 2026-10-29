# Forkop X

[![Releases](https://img.shields.io/github/v/release/Screamshow/forkop-x?label=releases)](https://github.com/Screamshow/forkop-x/releases)

> **Forkop X — независимый форк [Forkop](https://github.com/ushan0v/forkop) от [ushan0v](https://github.com/ushan0v).** Оригинальный Forkop - это бывший Podkop Plus, основанный на [Podkop](https://github.com/itdoginfo/podkop).

### Установка

```sh
wget -qO- https://mirror.51343.ru/forkop/install.sh | sh
```
### Canary ветка

```sh
wget -qO- https://mirror.51343.ru/forkop/install.sh | sh -s -- --channel canary
```


### Что нового в этом форке

OpenWrt SNAPSHOT и 25.12-SNAPSHOT поддерживаются условно.

[Beam WRT](https://github.com/timofey-maykov/be7000-openwrt) для Xiaomi BE7000
(aarch64_cortex-a73, apk) поддерживается условно.

⚙️ Что было сделано:
- Собственное зеркало OpenWRT под Mediatek/Filogic устройства, исключительно OpenWRT 24.10/25.12+
- Собственные зеркала для полной установки Forkop X со всеми зависимостями и листами маршрутизации без проблем при блокировке Github и репозиториев OpenWRT
- Кастомное ядро Xrust
- Поддержка hotswap правил маршрутизации без прерывания соединения
- Огромные оптимизации бэкенда, потребления RAM и CPU
- Вырезан функционал локального сервера
- QUIC при первой установке форсится выключенным
- URLTest режим показывает текущий узел
- Поддержка описания хостов из подписки
- Fallback для листов на jsDelivr и Github если зеркало недоступно
- Уменьшено количество полей и сложного функционала который нужен 0.1% пользователей
- Установка zapret-manager-stressozz так же полностью с зеркала из GUI
- Дополнительные встроенные листы для Blizzard, Sony, Bungie, Riot и т.д.
- Установка ядра Xrust по умолчанию на новых установках, уже установленное ядро сохраняется
- Измененный парсинг xray_json для поддержки URLTest от провайдера

✅ И естественно установка в 1 команду на свежем роутере. 

❗️ Важные нюансы:
- Сторонние подписки поддерживаются, но корректная работа не гарантируется
- User-Agent INCY/(версия Forkop X) для подписок

Телеграмм чат https://t.me/Flint_2/37459
