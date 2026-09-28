import json
import os
import sys
import signal

# Deliberately ignores TERM, so close must exercise its bounded KILL fallback.
signal.signal(signal.SIGTERM, signal.SIG_IGN)
prompt_id = None

def send(message):
    message['jsonrpc'] = '2.0'
    print(json.dumps(message), flush=True)

def result(id, value):
    send({'id': id, 'result': value})

def update(update_type, **fields):
    send({'method': 'session/update', 'params': {'sessionId': 'stub', 'update': {'sessionUpdate': update_type, **fields}}})

for line in sys.stdin:
    message = json.loads(line)
    with open('stub-events.jsonl', 'a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    params = message.get('params', {})
    if method == 'initialize':
        assert params['protocolVersion'] == 1
        assert params['clientCapabilities'] == {}
        result(message['id'], {'protocolVersion': 1})
    elif method == 'session/new':
        assert params['mcpServers'] == []
        assert params['_meta']['claudeCode']['options'] == {'strictMcpConfig': True, 'settingSources': ['user'], 'env': {'ENABLE_CLAUDEAI_MCP_SERVERS': 'false'}}
        if os.environ.get('STUB_NO_MODES'):
            result(message['id'], {'sessionId': 'stub'})
        else:
            result(message['id'], {'sessionId': 'stub', 'modes': {'availableModes': [{'id': 'ask'}, {'id': 'plan'}, {'id': 'agent'}]}})
    elif method == 'session/set_mode':
        assert params['modeId'] in ['ask', 'plan']
        result(message['id'], {})
    elif method == 'session/prompt':
        prompt_id = message['id']
        update('agent_message_chunk', content={'type': 'text', 'text': 'A finding. '})
        update('agent_thought_chunk', content={'type': 'text', 'text': 'Inspecting evidence.'})
        update('tool_call', toolCallId='tool-1', title='Proposed change', kind='edit', status='pending')
        update('plan', entries=[{'content': 'Review the change', 'status': 'pending', 'priority': 'high'}])
        send({'id': 'permission-1', 'method': 'session/request_permission', 'params': {
            'sessionId': 'stub', 'toolCall': {'toolCallId': 'tool-1', 'title': 'Proposed change', 'rawInput': {'path': 'example.txt'}},
            'options': [{'optionId': 'allow', 'name': 'Allow once', 'kind': 'allow_once'}, {'optionId': 'reject', 'name': 'Reject', 'kind': 'reject_once'}]}})
    elif method == 'session/cancel':
        if prompt_id is not None:
            result(prompt_id, {'stopReason': 'cancelled'})
            prompt_id = None
    elif message.get('id') == 'permission-1':
        outcome = message['result']['outcome']
        text = outcome.get('optionId', outcome['outcome'])
        update('tool_call_update', toolCallId='tool-1', status='completed' if text == 'allow' else 'failed')
        update('agent_message_chunk', content={'type': 'text', 'text': text})
        if prompt_id is not None:
            result(prompt_id, {'stopReason': 'end_turn'})
            prompt_id = None
# Keep the child alive after EOF to test close's kill fallback.
while True:
    signal.pause()
