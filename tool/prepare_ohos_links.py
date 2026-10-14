"""Register incoming links; AppLinksPlugin handles FlutterAbility cold/hot delivery."""
import argparse
import copy
import json
from pathlib import Path
import tempfile

from prepare_ohos_identity import read_json


LINK_SKILL = {
    'entities': ['entity.system.browsable'],
    'actions': ['ohos.want.action.viewData'],
    'domainVerify': False,
    'uris': [
        {'scheme': 'fluxdo'},
        {'scheme': 'discourse', 'host': 'auth_redirect'},
        {'scheme': 'http', 'host': 'linux.do'},
        {'scheme': 'https', 'host': 'linux.do'},
        {'scheme': 'http', 'host': 'www.linux.do'},
        {'scheme': 'https', 'host': 'www.linux.do'},
    ],
}
# shortcut: OpenHarmony Skill::MatchUri treats hosts literally; add explicit subdomains if needed.


def prepare(repo):
    path = repo / 'ohos/entry/src/main/module.json5'
    document = read_json(path)
    module = document['module']
    entries = [ability for ability in module['abilities']
               if ability['name'] == module['mainElement']]
    if len(entries) != 1:
        raise AssertionError('The module must have exactly one main ability')
    skills = entries[0].setdefault('skills', [])
    if LINK_SKILL not in skills:
        skills.append(copy.deepcopy(LINK_SKILL))
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n',
                        encoding='utf-8', newline='\n')


def self_test():
    with tempfile.TemporaryDirectory() as directory:
        repo = Path(directory)
        path = repo / 'ohos/entry/src/main/module.json5'
        path.parent.mkdir(parents=True)
        path.write_text('''{
          // Generated declarations and permissions must survive.
          "module": {"mainElement": "EntryAbility", "permissions": ["INTERNET"],
            "description": "https://linux.do/a//b",
            "abilities": [{"name": "EntryAbility", "icon": "$media:icon",
              "skills": [{"actions": ["ohos.want.action.home"],}]},
              {"name": "OtherAbility", "skills": []}],},
        }''', encoding='utf-8')
        original = read_json(path)
        identity = repo / 'ohos/AppScope/app.json5'
        identity.parent.mkdir(parents=True)
        identity.write_text('{"app":{"bundleName":"com.github.molchuan.cfluxdo"}}', encoding='utf-8')
        identity_before = identity.read_bytes()
        prepare(repo)
        first = path.read_bytes()
        prepare(repo)
        assert first == path.read_bytes()
        assert identity_before == identity.read_bytes()
        result = read_json(path)
        assert result['module']['abilities'][0]['skills'][-1] == LINK_SKILL
        result['module']['abilities'][0]['skills'].pop()
        assert result == original
        assert {'scheme': 'fluxdo'} in LINK_SKILL['uris']
        assert all('*' not in uri.get('host', '') for uri in LINK_SKILL['uris'])
        assert all(uri.get('host') for uri in LINK_SKILL['uris'] if uri['scheme'] in ('http', 'https'))
    print('Incoming link preparation: repeat, JSON5, identity and declarations preserved')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo', nargs='?', type=Path, default=Path.cwd())
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        prepare(args.repo.resolve())
