"""注册鸿蒙系统文件和剪贴板通道；保留其它插件、权限和资源。"""

import json
import os
from pathlib import Path
import re
import sys
import tempfile

from prepare_ohos_identity import read_json


PLUGIN = 'FluxdoSystemFilesPlugin'
IMPORT = f"import {PLUGIN} from '../fluxdo/system_files/{PLUGIN}';"
BINDINGS = [f'{PLUGIN}.abilityContext = this.context;',
            f'flutterEngine.getPlugins()?.add(new {PLUGIN}());']


def patch_entry(source):
    newline = '\r\n' if '\r\n' in source else '\n'
    anchor = re.compile(r'(?m)^([ \t]*)GeneratedPluginRegistrant\.registerWith\(flutterEngine\)[ \t]*;?[ \t]*(?:\r?\n|$)')
    matches = list(anchor.finditer(source))
    if len(matches) != 1:
        raise AssertionError('EntryAbility 必须保留唯一的 GeneratedPluginRegistrant')
    counts = [source.count(item) for item in [IMPORT, *BINDINGS]]
    if any(counts):
        if counts != [1, 1, 1]:
            raise AssertionError('系统文件插件注册不完整或重复')
        return source
    match = matches[0]
    original = match.group(0)
    if not original.endswith(('\r', '\n')):
        original += newline
    injected = ''.join(match.group(1) + item + newline for item in BINDINGS)
    return IMPORT + newline + source[:match.start()] + original + injected + source[match.end():]


def patch_permissions(manifest, strings):
    permissions = manifest['module'].setdefault('requestPermissions', [])
    names = [item['name'] for item in permissions]
    if len(names) != len(set(names)):
        raise AssertionError('工程权限重复')
    if 'ohos.permission.FILE_ACCESS_PERSIST' not in names:
        permissions.append({'name': 'ohos.permission.FILE_ACCESS_PERSIST'})
    if 'ohos.permission.READ_PASTEBOARD' not in names:
        permissions.append({
            'name': 'ohos.permission.READ_PASTEBOARD',
            'reason': '$string:fluxdo_clipboard_reason',
            'usedScene': {'abilities': ['EntryAbility'], 'when': 'inuse'},
        })
    entries = strings.setdefault('string', [])
    if not any(item['name'] == 'fluxdo_clipboard_reason' for item in entries):
        entries.append({'name': 'fluxdo_clipboard_reason', 'value': '用于您主动粘贴的文本和图片'})


def prepare(repo):
    repo = Path(repo).resolve()
    entry = repo / 'ohos/entry/src/main/ets/entryability/EntryAbility.ets'
    native = repo / f'ohos_support/system_files/{PLUGIN}.ets'
    manifest_path = repo / 'ohos/entry/src/main/module.json5'
    strings_path = repo / 'ohos/entry/src/main/resources/base/element/string.json'
    native_bytes = native.read_bytes()
    if b'com.fluxdo/public_file' not in native_bytes:
        raise AssertionError('系统文件通道合同不符')
    manifest, strings = read_json(manifest_path), read_json(strings_path)
    patch_permissions(manifest, strings)
    prepared = {
        entry: patch_entry(entry.read_bytes().decode('utf-8')).encode('utf-8'),
        repo / f'ohos/entry/src/main/ets/fluxdo/system_files/{PLUGIN}.ets': native_bytes,
        manifest_path: (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8'),
        strings_path: (json.dumps(strings, ensure_ascii=False, indent=2) + '\n').encode('utf-8'),
    }
    changed = []
    for destination, data in prepared.items():
        if destination.is_file() and destination.read_bytes() == data:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
            temporary.write(data)
            temporary_path = Path(temporary.name)
        try:
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)
        changed.append(destination)
    return changed


def self_test():
    with tempfile.TemporaryDirectory(prefix='fluxdo-files-') as temporary:
        repo = Path(temporary) / 'repo with spaces'
        entry = repo / 'ohos/entry/src/main/ets/entryability/EntryAbility.ets'
        entry.parent.mkdir(parents=True)
        source = ('import ExistingPlugin from "existing";\n'
                  'class EntryAbility {\n configureFlutterEngine(flutterEngine) {\n'
                  '  GeneratedPluginRegistrant.registerWith(flutterEngine);\n'
                  '  flutterEngine.getPlugins()?.add(new ExistingPlugin());\n }\n}\n').replace('\n', '\r\n')
        entry.write_bytes(source.encode('utf-8'))
        native = repo / f'ohos_support/system_files/{PLUGIN}.ets'
        native.parent.mkdir(parents=True)
        native.write_text('// com.fluxdo/public_file', encoding='utf-8')
        manifest = repo / 'ohos/entry/src/main/module.json5'
        manifest.write_text('// template\n{"module":{"requestPermissions":[{"name":"ohos.permission.MICROPHONE"},],},}', encoding='utf-8')
        strings = repo / 'ohos/entry/src/main/resources/base/element/string.json'
        strings.parent.mkdir(parents=True)
        strings.write_text('{"string":[{"name":"app_name","value":"cfluxdo"}]}', encoding='utf-8')
        assert len(prepare(repo)) == 4
        assert prepare(repo) == []
        patched = entry.read_bytes().decode('utf-8')
        assert patched.count('\n') == patched.count('\r\n')
        assert 'new ExistingPlugin()' in patched
        assert read_json(strings)['string'][0]['value'] == 'cfluxdo'
        names = [item['name'] for item in read_json(manifest)['module']['requestPermissions']]
        assert names == ['ohos.permission.MICROPHONE', 'ohos.permission.FILE_ACCESS_PERSIST', 'ohos.permission.READ_PASTEBOARD']
        for invalid in [source.replace('GeneratedPluginRegistrant', 'ChangedTemplate'), patched + BINDINGS[1], patched.replace(IMPORT, '')]:
            entry.write_bytes(invalid.encode('utf-8'))
            try:
                prepare(repo)
            except AssertionError:
                pass
            else:
                raise AssertionError('工程漂移必须拒绝')
            assert entry.read_bytes().decode('utf-8') == invalid
    print('系统文件准备自检通过：JSON5、幂等、保留插件/权限/资源、CRLF、漂移拒绝')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) <= 2:
        for destination in prepare(Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()):
            print(f'已准备系统文件：{destination.name}')
    else:
        raise SystemExit('用法：python prepare_ohos_files.py [CI 检出目录 | --self-test]')
