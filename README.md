# retail30-iac (1C Retail 3.0 on Linux) — IaC/Runbooks

Этот репозиторий автоматизирует развёртку тестовой/рабочей базы 1С (Retail 3.0) на Linux-сервере с PostgreSQL (1C build) и кластером 1С:Предприятие.
Умеет:
- поставить 1С (deb) при необходимости
- поднять/включить сервис 1С-сервера
- поправить /etc/hosts (чтобы FQDN не улетал в 127.0.1.1)
- создать/дропнуть базу PostgreSQL
- зарегистрировать инфобазу в кластере 1С
- восстановить базу из DT (режим `restore_dt`)
- подготовить пустую базу под последующую загрузку с Windows (режим `bootstrap_empty`)
- вывести понятный HELP по итогам

> Важное: артефакты (DT и deb-пакеты) **хранятся вне git**. Git хранит только код (playbooks/roles/scripts).

---

## Архитектура

- **Ansible-контроллер**: `root@Ansible`  
  Репозиторий: `/opt/git/retail30-iac`  
  Артефакты: `/srv/artifacts/retail30/`

- **Target (1С сервер)**: `root@1s-test` (пример: `192.168.2.202`)  
  На нём разворачивается PostgreSQL + 1С кластер, регистрируется база.

---

## Структура репозитория


retail30-iac/
ansible.cfg
inventory/
hosts.yml
group_vars/
all.yml
host_vars/ # НЕ коммитим, тут логины/пароли (локально)
playbooks/
retail30_restore_dt.yml
retail30_bootstrap_empty.yml
roles/
retail30/
tasks/main.yml
scripts/
retail_add_ib.sh # helper для запуска НА target (1s-test)
.gitignore
.yamllint


---

## Артефакты (DT и deb) — где должны лежать

На **Ansible-контроллере**:


/srv/artifacts/retail30/
dt/1Cv8.dt
deb/1c/.deb
deb/pg/.deb


Почему не в git:
- DT = 1.2GB, deb’ы сотни мегабайт. Git для этого не предназначен.
- Артефакты меняются редко, а код часто.
- Секьюрность и лицензирование: меньше шансов случайно утечь.

---

## Что нужно скачать заранее

1) **DT-файл** базы (dump информационной базы)
- пример: `1Cv8.dt`

2) **deb пакеты 1С** (server/common/nls и т.п.)
- папка: `/srv/artifacts/retail30/deb/1c/`

3) **PostgreSQL 1C build** (в нашем стенде это `18.x (Debian ...-2.1C)`)
- папка: `/srv/artifacts/retail30/deb/pg/`

> Альтернатива deb’ам: подключить репозиторий поставщика и ставить через apt.
> Но это зависит от того, как именно у вас принято получать пакеты (локальный repo, зеркала, интернет, лицензии).
> В стенде используем “офлайн-артефакты”, чтобы было воспроизводимо.

---

## Настройка inventory

### 1) inventory/hosts.yml
Пример:

```yaml
all:
  hosts:
    1s-test:
      ansible_host: 192.168.2.202
      ansible_user: root
2) inventory/group_vars/all.yml (главные переменные)

Тут меняются:

версии

имя базы

пути к артефактам на контроллере

пути на target

3) inventory/host_vars/1s-test.yml (секреты, НЕ В GIT)

Файл НЕ коммитится, лежит локально на контроллере:

ansible_user: root
ansible_password: "CHANGE_ME"

Рекомендуется:

либо SSH-ключи

либо ansible-vault для пароля

Режимы развёртки
A) restore_dt (залить DT в PostgreSQL + зарегистрировать в 1С)

Команда:

cd /opt/git/retail30-iac
ansible-playbook playbooks/retail30_restore_dt.yml

Что делает:

синхронизирует DT на target

проверяет sha256 DT (идемпотентность)

если DT поменялся или базы нет: дропает/создаёт DB, делает ibcmd create --restore, регистрирует базу в кластере

B) bootstrap_empty (создать пустую базу и зарегистрировать)

Команда:

cd /opt/git/retail30-iac
ansible-playbook playbooks/retail30_bootstrap_empty.yml

Когда нужно:

хочешь создать “пустую оболочку” на сервере

затем зайти с Windows (конфигуратор) и загрузить DT вручную

Быстрые проверки (перед реальным запуском)

Проверка доступности:

ansible -i inventory/hosts.yml all -m ping

Синтаксис:

ansible-playbook playbooks/retail30_restore_dt.yml --syntax-check
ansible-playbook playbooks/retail30_bootstrap_empty.yml --syntax-check

Dry-run (важно: check-mode не должен падать на rsync/restore, он покажет изменения “на бумаге”):

ansible-playbook playbooks/retail30_restore_dt.yml --check --diff
ansible-playbook playbooks/retail30_bootstrap_empty.yml --check --diff
Что делать на Windows после bootstrap_empty

Цель: загрузить DT в уже созданную базу.

Установи Windows-клиент 1С той же версии (или совместимой).

Открой конфигуратор и подключись к базе:

строка подключения вида:

1s-test.portkkm.local\retail30

В конфигураторе:

Администрирование → Загрузить информационную базу

выбрать *.dt

Либо через командную строку Windows (если есть 1cv8.exe):

"C:\Program Files\1cv8\8.3.xx.xxxx\bin\1cv8.exe" DESIGNER /S"1s-test.portkkm.local\retail30" /RestoreIB"X:\path\1Cv8.dt" /DisableStartupMessages
Скрипт на target: scripts/retail_add_ib.sh

Этот скрипт запускается на сервере 1s-test, если надо быстро добавить/зарегистрировать новую инфобазу.

Установка на target

Скопировать на target:

scp scripts/retail_add_ib.sh root@192.168.2.202:/root/retail_add_ib.sh
ssh root@192.168.2.202 "chmod +x /root/retail_add_ib.sh"
Запуск на target
/root/retail_add_ib.sh

Скрипт спрашивает:

версию платформы (или пытается найти установленную)

имя базы (db_name)

пользователя/пароль PostgreSQL (db_user/db_pwd)

адрес RAS (обычно localhost:1545)

И делает:

создание БД

создание/обновление роли

регистрацию в кластере 1С

Где смотреть результат

На target:

список баз в кластере:

sudo -u usr1cv8 /opt/1cv8/x86_64/<VER>/rac infobase summary list --cluster="<CLUSTER_UUID>" "localhost:1545"

состояние сервиса:

systemctl status srv1cv8-<VER>@default.service -l --no-pager

проверка портов:

ss -lntp | grep -E ':(1540|1541|1545|1560)\b'
Типовые грабли

FQDN резолвится в 127.0.1.1 → ломает RAS/RAC и подключения.
Поэтому роль правит /etc/hosts.

PostgreSQL “не пригоден для использования” при restore → чаще всего:

база создана “не тем способом”

не хватило прав на расширения/языки

restore делали отдельно от create (ibcmd любит create+restore одним шагом)

Пароли/секреты:
inventory/host_vars не должен попасть в git. Используй vault или ключи.
