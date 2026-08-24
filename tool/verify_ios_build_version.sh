#!/bin/sh

set -eu

if [ "$#" -ne 0 ]; then
  echo "error: 未対応の引数です: $*" >&2
  exit 64
fi

case "${ACTION:-}" in
  "" | install) ;;
  *) exit 0 ;;
esac

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
pubspec="$project_root/pubspec.yaml"
generated_config="$project_root/ios/Flutter/Generated.xcconfig"
generated_environment="$project_root/ios/Flutter/flutter_export_environment.sh"

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

actual_build_name=${FLUTTER_BUILD_NAME:-}
actual_build_number=${FLUTTER_BUILD_NUMBER:-}

if [ "$actual_build_name" != "$expected_build_name" ] ||
  [ "$actual_build_number" != "$expected_build_number" ]; then
  echo "error: Xcodeのversionがpubspec.yamlと一致しません。pubspec=${expected_build_name}+${expected_build_number}、Xcode=${actual_build_name:-未設定}+${actual_build_number:-未設定}" >&2
  generated_build_name=""
  generated_build_number=""
  environment_build_name=""
  environment_build_number=""
  if [ -f "$generated_config" ]; then
    generated_build_name=$(sed -n 's/^FLUTTER_BUILD_NAME=//p' "$generated_config" | tail -n 1)
    generated_build_number=$(sed -n 's/^FLUTTER_BUILD_NUMBER=//p' "$generated_config" | tail -n 1)
  fi
  if [ -f "$generated_environment" ]; then
    environment_build_name=$(sed -n 's/^export "FLUTTER_BUILD_NAME=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1)
    environment_build_number=$(sed -n 's/^export "FLUTTER_BUILD_NUMBER=\(.*\)"$/\1/p' "$generated_environment" | tail -n 1)
  fi

  if [ "$generated_build_name" = "$expected_build_name" ] &&
    [ "$generated_build_number" = "$expected_build_number" ] &&
    [ "$environment_build_name" = "$expected_build_name" ] &&
    [ "$environment_build_number" = "$expected_build_number" ]; then
    echo "error: 生成設定は${expected_build_name}+${expected_build_number}で正しいため、Xcodeを閉じてworkspaceを開き直してください。再発する場合はXcode側のFLUTTER_BUILD_NAME／FLUTTER_BUILD_NUMBER overrideを削除してください。" >&2
  elif /bin/sh "$script_directory/sync_ios_xcode_config.sh"; then
    echo "error: 生成設定を${expected_build_name}+${expected_build_number}へ同期し、このArchiveを中止しました。Xcodeでもう一度Archiveしてください。" >&2
  else
    echo "error: 生成設定の同期にも失敗しました。上記エラーを確認してください。" >&2
  fi
  exit 1
fi

echo "Xcode archive versionを${actual_build_name}+${actual_build_number}で検証しました。"
