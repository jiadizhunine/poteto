#!/usr/bin/python3
import json, os, sys

home = os.environ['CODEX_HOME']
assert os.path.realpath(os.getcwd()) == os.path.realpath(home) and os.path.realpath(os.environ['HOME']) != os.path.realpath(home)
config = open(os.path.join(home, 'config.toml')).read()
assert 'remote_plugin = false' in config and '[model_providers.openai]' not in config
flags = ['shell_tool', 'unified_exec', 'multi_agent', 'plugins', 'apps', 'code_mode', 'browser_use', 'computer_use', 'image_generation', 'remote_plugin']
features = {x: False for x in flags}
features.update(skip_host_skill_discovery=True, unbounded_connection_retries=False)
turns = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    params = request.get('params', {})
    if method == 'initialized':
        continue
    if method == 'initialize': result = {'codexHome': home}
    elif method == 'config/read': result = {'config': {'cli_auth_credentials_store': 'file', 'web_search': 'disabled', 'features': features}}
    elif method == 'account/login/start':
        assert set(params) == {'type', 'accessToken', 'chatgptAccountId', 'chatgptPlanType'}
        assert params['accessToken'] == 'fixture-access'
        result = {'type': 'chatgptAuthTokens'}
    elif method == 'account/read':
        assert params == {'refreshToken': False}
        result = {'account': {'type': 'chatgpt', 'email': 'a@example.invalid'}, 'workspaceRouting': {'chatgptAccountId': 'workspace'}}
    elif method == 'model/list': result = {'data': [{'isDefault': True, 'model': 'fixture-default', 'inputModalities': ['text'], 'supportedReasoningEfforts': [{'reasoningEffort': 'high'}, {'reasoningEffort': 'low'}]}], 'nextCursor': None}
    elif method == 'thread/start':
        assert params['model'] == 'fixture-default' and params['ephemeral'] and params['dynamicTools'] == [] and params['environments'] == [] and params['baseInstructions'] == 'Reply exactly OK. Do not use tools.'
        result = {'model': 'fixture-default', 'modelProvider': 'openai', 'approvalPolicy': 'never', 'sandbox': {'type': 'readOnly'}, 'thread': {'id': 'thread', 'ephemeral': True, 'path': None}}
    elif method == 'turn/start':
        turns += 1
        assert turns == 1 and params['effort'] == 'low' and params['input'][0]['text'] == 'Reply exactly OK. Do not use tools.'
        result = {'turn': {'id': 'turn'}}
    else: raise AssertionError(method)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    if method == 'turn/start':
        print(json.dumps({'method': 'item/completed', 'params': {'threadId': 'thread', 'turnId': 'turn', 'item': {'type': 'agentMessage', 'text': 'OK'}}}), flush=True)
        print(json.dumps({'method': 'turn/completed', 'params': {'threadId': 'thread', 'turn': {'id': 'turn', 'status': 'completed'}}}), flush=True)
