#!/usr/bin/env bash

# =============================================================================
# Копирует конфиденциальные / git-игнорируемые файлы проекта Xabber
# Директория назначения указывается как первый аргумент
# =============================================================================

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Использование:"
    echo "    $0 ПУТЬ_КУДА_КОПИРОВАТЬ"
    echo ""
    echo "Примеры:"
    echo "    $0 ../xabber-private-files"
    echo "    $0 /tmp/xabber-clean-copy"
    echo "    $0 \"~/Backup/Xabber Secrets 2025\""
    exit 1
fi

TARGET_DIR="$1"

# Проверяем, существует ли уже такая папка
if [ -e "$TARGET_DIR" ] && [ ! -d "$TARGET_DIR" ]; then
    echo "Ошибка: $TARGET_DIR существует, но это не директория"
    exit 2
fi

# Создаём, если нет
mkdir -p "$TARGET_DIR" || {
    echo "Не удалось создать директорию: $TARGET_DIR"
    exit 3
}

SOURCE_DIR="."

# ────────────────────────────────────────────────
# Список путей (относительно SOURCE_DIR)
# ────────────────────────────────────────────────

declare -a ITEMS_TO_COPY=(
    "xabber/*.lproj"
    "xabber/Backgrounds.xcassets"
    "xabber/Info.plist"
    "xabber/Masks.xcassets"
    "xabber/common_config.plist"
    "xabber/credential_store.plist"
    "xabber/proofreading.json"
    "xabber/push_service.plist"
    "xabber/subscribtions_secret.plist"
    "xabber/translations"
    "xabber/translations.json"
    "xabber/whitelabel_res.xcassets"
    "xabber/xabber.entitlements"
    "xabber/XASettingsDebug.plist"
)

# ────────────────────────────────────────────────
# Логика копирования
# ────────────────────────────────────────────────

echo "Копирование конфиденциальных/игнорируемых файлов..."
echo "Источник      : $SOURCE_DIR"
echo "Цель          : $TARGET_DIR"
echo "Количество шаблонов: ${#ITEMS_TO_COPY[@]}"
echo ""

copied=0
failed=0

for pattern in "${ITEMS_TO_COPY[@]}"; do
    while IFS= read -r -d '' item; do
        # относительный путь от SOURCE_DIR
        rel_path="${item#"$SOURCE_DIR"/}"
        if [ "$rel_path" = "$item" ]; then
            rel_path="${item#./}"  # на случай, если SOURCE_DIR = .
        fi

        target_path="$TARGET_DIR/$rel_path"

        mkdir -p "$(dirname "$target_path")" || {
            echo "[mkdir failed] $rel_path"
            ((failed++))
            continue
        }

        if cp -a "$item" "$target_path"; then
            echo "[ OK ] $rel_path"
            ((copied++))
        else
            echo "[FAIL] $rel_path"
            ((failed++))
        fi
    done < <(find "$SOURCE_DIR" -path "$SOURCE_DIR/$pattern" -print0 2>/dev/null || true)
done

echo ""
echo "───────────────────────────────────────────────"
echo "Успешно скопировано : $copied"
echo "С ошибками          : $failed"
echo ""

if [ $failed -eq 0 ]; then
    echo "Готово ✓"
    exit 0
else
    echo "Завершено с ошибками ✗"
    exit 1
fi
