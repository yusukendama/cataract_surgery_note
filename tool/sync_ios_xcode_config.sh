#!/bin/sh

set -eu

if [ "$#" -ne 0 ]; then
  echo "error: 未対応の引数です: $*" >&2
  exit 64
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
generated_config="$project_root/ios/Flutter/Generated.xcconfig"
generated_environment="$project_root/ios/Flutter/flutter_export_environment.sh"
pubspec="$project_root/pubspec.yaml"
flutter_executable=""

version_value=$(awk '$1 == "version:" { print $2; exit }' "$pubspec")
version_value=${version_value#\"}
version_value=${version_value%\"}
version_value=${version_value#\'}
version_value=${version_value%\'}

case "$version_value" in
  *+*)
    expected_build_name=${version_value%%+*}
    expected_build_number=${version_value#*+}
    ;;
  *)
    echo "error: pubspec.yamlのversionにビルド番号（+N）がありません。" >&2
    exit 1
    ;;
esac

if [ -z "$expected_build_name" ] || [ -z "$expected_build_number" ]; then
  echo "error: pubspec.yamlのversionまたはbuild番号が空です。" >&2
  exit 1
fi

is_dot_separated_number() {
  case "$1" in
    "" | .* | *. | *..* | *[!0-9.]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_three_part_version() {
  remaining_parts=${1#*.}
  [ "$remaining_parts" != "$1" ] || return 1
  third_part=${remaining_parts#*.}
  [ "$third_part" != "$remaining_parts" ] || return 1
  case "$third_part" in
    *.*) return 1 ;;
    *) return 0 ;;
  esac
}

if ! is_dot_separated_number "$expected_build_name" ||
  ! is_three_part_version "$expected_build_name" ||
  ! is_dot_separated_number "$expected_build_number"; then
  echo "error: iOSのversionはN.N.N、build番号は数字をピリオドで区切った形式にしてください: $version_value" >&2
  exit 1
fi

actual_build_name=""
actual_build_number=""
environment_build_name=""
environment_build_number=""
if [ -f "$generated_config" ]; then
  actual_build_name=$(
    sed -n 's/^FLUTTER_BUILD_NAME=//p' "$generated_config" | tail -n 1
  )
  actual_build_number=$(
    sed -n 's/^FLUTTER_BUILD_NUMBER=//p' "$generated_config" | tail -n 1
  )
fi
if [ -f "$generated_environment" ]; then
  environment_build_name=$(
    sed -n 's/^export "FLUTTER_BUILD_NAME=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1
  )
  environment_build_number=$(
    sed -n 's/^export "FLUTTER_BUILD_NUMBER=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1
  )
fi

if [ "$actual_build_name" = "$expected_build_name" ] &&
  [ "$actual_build_number" = "$expected_build_number" ] &&
  [ "$environment_build_name" = "$expected_build_name" ] &&
  [ "$environment_build_number" = "$expected_build_number" ]; then
  chmod 755 "$generated_environment"
  echo "iOS versionは${actual_build_name}+${actual_build_number}に同期済みです。"
  exit 0
fi

if [ "${ACTION:-}" = "install" ] && [ -n "${TARGET_BUILD_DIR:-}" ]; then
  if [ ! -f "$generated_config" ] || [ ! -f "$generated_environment" ]; then
    echo "error: iOSの生成設定が見つかりません。Archive前にtool/sync_ios_xcode_config.shを実行してください。" >&2
    exit 1
  fi

  temporary_config=""
  temporary_environment=""
  cleanup_temporary_files() {
    [ -z "${temporary_config:-}" ] || rm -f -- "$temporary_config"
    [ -z "${temporary_environment:-}" ] || rm -f -- "$temporary_environment"
  }
  trap cleanup_temporary_files 0 1 2 15
  temporary_config=$(mktemp "${generated_config}.version-sync.XXXXXX")
  temporary_environment=$(mktemp "${generated_environment}.version-sync.XXXXXX")

  awk -v name="$expected_build_name" -v number="$expected_build_number" '
    BEGIN { found_name = 0; found_number = 0 }
    /^FLUTTER_BUILD_NAME=/ {
      $0 = "FLUTTER_BUILD_NAME=" name
      found_name = 1
    }
    /^FLUTTER_BUILD_NUMBER=/ {
      $0 = "FLUTTER_BUILD_NUMBER=" number
      found_number = 1
    }
    { print }
    END { if (!found_name || !found_number) exit 1 }
  ' "$generated_config" >"$temporary_config"
  awk -v name="$expected_build_name" -v number="$expected_build_number" '
    BEGIN { found_name = 0; found_number = 0 }
    /^export "FLUTTER_BUILD_NAME=/ {
      $0 = "export \"FLUTTER_BUILD_NAME=" name "\""
      found_name = 1
    }
    /^export "FLUTTER_BUILD_NUMBER=/ {
      $0 = "export \"FLUTTER_BUILD_NUMBER=" number "\""
      found_number = 1
    }
    { print }
    END { if (!found_name || !found_number) exit 1 }
  ' "$generated_environment" >"$temporary_environment"

  chmod 644 "$temporary_config"
  chmod 755 "$temporary_environment"
  mv "$temporary_config" "$generated_config"
  temporary_config=""
  mv "$temporary_environment" "$generated_environment"
  temporary_environment=""
else
  if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
    flutter_executable="$FLUTTER_ROOT/bin/flutter"
  fi

  if [ -z "$flutter_executable" ] && [ -f "$generated_config" ]; then
    configured_flutter_root=$(
      sed -n 's/^FLUTTER_ROOT=//p' "$generated_config" | head -n 1
    )
    if [ -n "$configured_flutter_root" ] &&
      [ -x "$configured_flutter_root/bin/flutter" ]; then
      flutter_executable="$configured_flutter_root/bin/flutter"
    fi
  fi

  if [ -z "$flutter_executable" ]; then
    flutter_executable=$(command -v flutter 2>/dev/null || true)
  fi

  if [ -z "$flutter_executable" ] || [ ! -x "$flutter_executable" ]; then
    echo "error: Flutter SDKが見つかりません。flutter pub getを実行してからArchiveしてください。" >&2
    exit 1
  fi

  cd "$project_root"
  "$flutter_executable" build ios --config-only --release \
    --build-name="$expected_build_name" \
    --build-number="$expected_build_number"
fi

if [ ! -f "$generated_config" ] || [ ! -f "$generated_environment" ]; then
  echo "error: iOSの生成設定が見つかりません。flutter pub getを実行してください。" >&2
  exit 1
fi

chmod 755 "$generated_environment"

actual_build_name=$(
  sed -n 's/^FLUTTER_BUILD_NAME=//p' "$generated_config" | tail -n 1
)
actual_build_number=$(
  sed -n 's/^FLUTTER_BUILD_NUMBER=//p' "$generated_config" | tail -n 1
)
environment_build_name=$(
  sed -n 's/^export "FLUTTER_BUILD_NAME=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1
)
environment_build_number=$(
  sed -n 's/^export "FLUTTER_BUILD_NUMBER=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1
)

if [ "$actual_build_name" != "$expected_build_name" ] ||
  [ "$actual_build_number" != "$expected_build_number" ] ||
  [ "$environment_build_name" != "$expected_build_name" ] ||
  [ "$environment_build_number" != "$expected_build_number" ]; then
  echo "error: iOSのversion同期に失敗しました。pubspec=$version_value、xcconfig=$actual_build_name+$actual_build_number、environment=$environment_build_name+$environment_build_number" >&2
  exit 1
fi

echo "iOS versionを${actual_build_name}+${actual_build_number}へ同期しました。"
