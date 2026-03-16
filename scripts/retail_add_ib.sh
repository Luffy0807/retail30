#!/usr/bin/env bash
set -euo pipefail

ONEC_OS_USER="${ONEC_OS_USER:-usr1cv8}"
ONEC_OS_GROUP="${ONEC_OS_GROUP:-grp1cv8}"
DEFAULT_LOCALE="${DEFAULT_LOCALE:-ru}"
DEFAULT_DB_SERVER="${DEFAULT_DB_SERVER:-localhost}"
DEFAULT_RAS="${DEFAULT_RAS:-localhost:1545}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok()  { echo "[OK] $*"; }
warn(){ echo "[WARN] $*" >&2; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Запусти от root."; }

detect_onec_bin() {
  local base="/opt/1cv8/x86_64"
  [ -d "$base" ] || die "Не найдено $base. 1С не установлена?"

  local ver=""
  if [ -n "${ONEC_VER:-}" ]; then
    ver="$ONEC_VER"
  else
    # берем только подкаталоги (mindepth 1) и только похожие на версию (начинаются с цифры)
    ver="$(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | grep -E '^[0-9]+' \
      | sort -V \
      | tail -n 1 || true)"
  fi

  [ -n "$ver" ] || die "Не удалось определить версию 1С в $base. Укажи ONEC_VER=8.3.x.yyyy"
  BIN="$base/$ver"
  RAC="$BIN/rac"
  IBCMD="$BIN/ibcmd"

  [ -x "$RAC" ] || die "Нет rac: $RAC"
  ok "1C BIN = $BIN"
}

check_postgres() {
  command -v psql >/dev/null 2>&1 || die "psql не найден. PostgreSQL установлен?"
  sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL не отвечает (sudo -u postgres psql)."
  ok "PostgreSQL доступен"
}

get_cluster_uuid() {
  local ras="$1"
  local uuid
  uuid="$(sudo -u "$ONEC_OS_USER" "$RAC" cluster list "$ras" 2>/dev/null \
    | awk -F': ' '$1=="cluster"{print $2; exit}')"
  [ -n "${uuid:-}" ] || die "Не смог получить CLUSTER_UUID (rac cluster list $ras). Проверь ras/кластер."
  echo "$uuid"
}

find_infobase_uuid_by_name() {
  local ras="$1" cluster="$2" name="$3"
  sudo -u "$ONEC_OS_USER" "$RAC" infobase summary list --cluster="$cluster" "$ras" \
    | awk -F': ' -v n="$name" '
        $1=="infobase"{u=$2}
        $1=="name" && $2==n{print u; exit}
      '
}

drop_infobase_if_exists() {
  local ras="$1" cluster="$2" name="$3"
  local u
  u="$(find_infobase_uuid_by_name "$ras" "$cluster" "$name" || true)"
  if [ -n "${u:-}" ]; then
    warn "Инфобаза '$name' уже зарегистрирована (UUID=$u)."
    read -r -p "Снять регистрацию (rac infobase drop)? (yes/no) " ans
    [ "$ans" = "yes" ] || die "Ок, не трогаю. Выход."
    sudo -u "$ONEC_OS_USER" "$RAC" infobase drop --cluster="$cluster" --infobase="$u" "$ras" || true
    ok "Регистрация инфобазы снята"
  fi
}

drop_db_if_exists() {
  local db="$1"
  local exists
  exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}';" | tr -d '[:space:]' || true)"
  if [ "$exists" = "1" ]; then
    warn "База PostgreSQL '$db' уже существует."
    read -r -p "Удалить БД принудительно (DROP DATABASE ... WITH FORCE)? (yes/no) " ans
    [ "$ans" = "yes" ] || die "Ок, не трогаю. Выход."
    sudo -u postgres psql -d postgres -c "DROP DATABASE IF EXISTS ${db} WITH (FORCE);" >/dev/null
    ok "БД удалена"
  fi
}

ensure_role_and_temp_superuser() {
  local user="$1" pwd="$2"
  sudo -u postgres psql -d postgres -c "DO \$\$BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${user}') THEN
    CREATE ROLE ${user} LOGIN PASSWORD '${pwd}';
  ELSE
    ALTER ROLE ${user} WITH PASSWORD '${pwd}';
  END IF;
  END\$\$;" >/dev/null
  sudo -u postgres psql -d postgres -c "ALTER ROLE ${user} WITH SUPERUSER;" >/dev/null
  ok "Роль ${user}: пароль задан, SUPERUSER временно включен"
}

remove_superuser() {
  local user="$1"
  sudo -u postgres psql -d postgres -c "ALTER ROLE ${user} WITH NOSUPERUSER;" >/dev/null
  ok "Роль ${user}: SUPERUSER снят"
}

create_empty_db_and_register() {
  local ras="$1" cluster="$2" ib_name="$3" db_server="$4" db_name="$5" db_user="$6" db_pwd="$7" locale="$8"
  sudo -u "$ONEC_OS_USER" "$RAC" infobase create \
    --cluster="$cluster" \
    --create-database \
    --name="$ib_name" \
    --dbms=PostgreSQL \
    --db-server="$db_server" \
    --db-name="$db_name" \
    --db-user="$db_user" \
    --db-pwd="$db_pwd" \
    --locale="$locale" \
    --license-distribution=allow \
    "$ras"
  ok "Пустая инфобаза создана и зарегистрирована"
}

restore_dt_and_register() {
  local ras="$1" cluster="$2" ib_name="$3" db_server="$4" db_name="$5" db_user="$6" db_pwd="$7" locale="$8" dt_path="$9"

  [ -x "$IBCMD" ] || die "ibcmd не найден/не исполняемый: $IBCMD"
  [ -f "$dt_path" ] || die "DT файл не найден: $dt_path"

  local dt_dest="/home/${ONEC_OS_USER}/$(basename "$dt_path")"
  install -o "$ONEC_OS_USER" -g "$ONEC_OS_GROUP" -m 0640 "$dt_path" "$dt_dest"
  ok "DT скопирован: $dt_dest"

  local data_root="/var/lib/retail30"
  local log_root="/var/log/retail30"
  mkdir -p "$data_root" "$log_root"
  chown -R "$ONEC_OS_USER:$ONEC_OS_GROUP" "$data_root" "$log_root"

  local data_dir="${data_root}/ibcmd_${db_name}_$(date +%F_%H%M%S)"
  local log_file="${log_root}/ibcmd_${db_name}_create_restore_$(date +%F_%H%M%S).log"
  mkdir -p "$data_dir"
  chown -R "$ONEC_OS_USER:$ONEC_OS_GROUP" "$data_dir"

  sudo -u "$ONEC_OS_USER" "$IBCMD" infobase create \
    --dbms=PostgreSQL \
    --db-server="$db_server" \
    --db-name="$db_name" \
    --db-user="$db_user" \
    --db-pwd="$db_pwd" \
    --create-database \
    --restore="$dt_dest" \
    --data="$data_dir" \
    >"$log_file" 2>&1

  ok "DT восстановлен. Лог: $log_file"

  if sudo -u "$ONEC_OS_USER" "$RAC" infobase summary list --cluster="$cluster" "$ras" | grep -qE "^name\s+: ${ib_name}\b"; then
    ok "Инфобаза уже зарегистрирована в кластере (${ib_name})"
  else
    sudo -u "$ONEC_OS_USER" "$RAC" infobase create \
      --cluster="$cluster" \
      --name="$ib_name" \
      --dbms=PostgreSQL \
      --db-server="$db_server" \
      --db-name="$db_name" \
      --db-user="$db_user" \
      --db-pwd="$db_pwd" \
      --locale="$locale" \
      --license-distribution=allow \
      "$ras"
    ok "Инфобаза зарегистрирована в кластере"
  fi
}

post_checks() {
  local ras="$1" cluster="$2" db_name="$3" onec_ver="$4"
  echo
  echo "=== ПРОВЕРКИ ==="
  sudo -u postgres psql -d postgres -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datname='${db_name}';" || true
  sudo -u postgres psql -d "${db_name}" -c "SELECT count(*) AS tables
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE c.relkind='r'
    AND n.nspname NOT IN ('pg_catalog','information_schema')
    AND n.nspname NOT LIKE 'pg_toast%';" || true
  sudo -u "$ONEC_OS_USER" "/opt/1cv8/x86_64/${onec_ver}/rac" infobase summary list --cluster="$cluster" "$ras" || true
}

need_root
detect_onec_bin
check_postgres

echo
echo "Выбери режим:"
echo "  1) Создать ПУСТУЮ инфобазу (DB + регистрация)"
echo "  2) Восстановить из DT (ibcmd create+restore + регистрация)"
read -r -p "Режим [1/2]: " MODE

read -r -p "RAS адрес [${DEFAULT_RAS}]: " RAS
RAS="${RAS:-$DEFAULT_RAS}"

read -r -p "DB server [${DEFAULT_DB_SERVER}]: " DB_SERVER
DB_SERVER="${DB_SERVER:-$DEFAULT_DB_SERVER}"

read -r -p "Locale [${DEFAULT_LOCALE}]: " LOCALE
LOCALE="${LOCALE:-$DEFAULT_LOCALE}"

read -r -p "Имя инфобазы (как в кластере 1С), например retail30: " IB_NAME
[ -n "${IB_NAME:-}" ] || die "Имя инфобазы пустое."

read -r -p "Имя PostgreSQL БД [${IB_NAME}]: " DB_NAME
DB_NAME="${DB_NAME:-$IB_NAME}"

read -r -p "PostgreSQL пользователь [${DB_NAME}]: " DB_USER
DB_USER="${DB_USER:-$DB_NAME}"

read -r -s -p "Пароль PostgreSQL пользователя ${DB_USER}: " DB_PWD
echo
[ -n "${DB_PWD:-}" ] || die "Пароль пустой."

ONEC_VER="$(basename "$BIN")"
CLUSTER_UUID="$(get_cluster_uuid "$RAS")"
ok "CLUSTER_UUID = $CLUSTER_UUID"

drop_infobase_if_exists "$RAS" "$CLUSTER_UUID" "$IB_NAME"
drop_db_if_exists "$DB_NAME"

ensure_role_and_temp_superuser "$DB_USER" "$DB_PWD"

if [ "$MODE" = "1" ]; then
  create_empty_db_and_register "$RAS" "$CLUSTER_UUID" "$IB_NAME" "$DB_SERVER" "$DB_NAME" "$DB_USER" "$DB_PWD" "$LOCALE"
elif [ "$MODE" = "2" ]; then
  read -r -p "Путь к DT файлу (например /root/dist/1Cv8.dt): " DT_PATH
  [ -n "${DT_PATH:-}" ] || die "DT путь пустой."
  restore_dt_and_register "$RAS" "$CLUSTER_UUID" "$IB_NAME" "$DB_SERVER" "$DB_NAME" "$DB_USER" "$DB_PWD" "$LOCALE" "$DT_PATH"
else
  remove_superuser "$DB_USER"
  die "Неизвестный режим: $MODE"
fi

remove_superuser "$DB_USER"
post_checks "$RAS" "$CLUSTER_UUID" "$DB_NAME" "$ONEC_VER"

echo
echo "=== ГОТОВО ==="
echo "Инфобаза: ${IB_NAME}"
echo "PostgreSQL DB: ${DB_NAME}, user: ${DB_USER}"
echo "Подключение (Windows/клиент):  ${HOSTNAME} \\ ${IB_NAME}"
