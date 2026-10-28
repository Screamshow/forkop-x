# Forkop X

[![Releases](https://img.shields.io/github/v/release/Screamshow/forkop-x?label=releases)](https://github.com/Screamshow/forkop-x/releases)

> **Forkop X — независимый форк [Forkop](https://github.com/ushan0v/forkop) от [ushan0v](https://github.com/ushan0v).** Оригинальный Forkop — это бывший Podkop Plus, основанный на [Podkop](https://github.com/itdoginfo/podkop).

### Установка

```sh
wget -qO- https://mirror.51343.ru/forkop/install.sh | sh
```
### Canary ветка

```sh
wget -qO- https://mirror.51343.ru/forkop/install.sh | sh -s -- --channel canary
```

OpenWrt SNAPSHOT и 25.12-SNAPSHOT поддерживаются условно

### Что нового в этом форке

⚙️ Что было сделано:
- Собственное зеркало OpenWRT под Mediatek/Filogic устройства, исключительно OpenWRT 24.10/25.12+
- Собственные зеркала для полной установки форкоп со всеми зависимостями и листами маршрутизации
- Уменьшение количества хардкода который вызывает невалидный запуск sing-box (доступность листов как пример)
- Вырезан функционал локального сервера
- QUIC при первой установке форсится выключенным
- URLTest режим показывает текущий узел
- Стартовый порядок узлов провайдерского URLTest случайно смещается при
  генерации конфигурации; последующий выбор остаётся за sing-box
- Поддержка описания хостов из подписки
- Fallback для листов на jsDelivr и Github если зеркало недоступно
- Уменьшено количество полей и сложного функционала который нужен 0.1% пользователей
- Установка zapret-manager-stressozz так же полностью с зеркала из GUI
- Дополнительные встроенные листы для Blizzard, Sony, Bungie, Riot и т.д.
- Установка ядра Xrust по умолчанию на новых установках; уже установленное ядро сохраняется при обновлении
- Корректный парсинг xray_json для поддержки URLTest от провайдера

✅ И естественно установка в 1 команду на свежем роутере. 

❗️ Важные нюансы:
- Сторонние подписки поддерживаются, но корректная работа не гарантируется
- User-Agent INCY/(версия Forkop X) для подписок

Телеграмм чат https://t.me/Flint_2/37459
