"""Check the exact Compose model allowlist against project-prefixed bypasses."""
import json
import re
import subprocess
from urllib.parse import unquote

config = json.loads(subprocess.check_output([
    'docker', 'compose', '-f', 'docker-compose.snippet.yml', 'config', '--format', 'json']))
labels = config['services']['headroom']['labels']
rule = labels['traefik.http.routers.headroom.rule']
pattern = re.compile(rule.split('PathRegexp(`')[1].split('`)')[0])
for prefix in ('', '/p/example', '/p/project%20name'):
    for path in ('/v1/messages', '/v1/messages/count_tokens', '/v1/chat/completions',
                 '/v1/responses', '/v1/responses/id', '/v1/models',
                 '/v1beta/models/gemini:generateContent', '/v1internal:streamGenerateContent'):
        assert pattern.fullmatch(prefix + path), prefix + path
    for path in ('/v1/retrieve', '/v1/retrieve/stats', '/v1/retrieve/abc',
                 '/v1/retrieve/tool_call', '/dashboard', '/stats', '/healthz',
                 '/v1/telemetry/export', '/unknown-sensitive', '/p/nested/v1/retrieve'):
        assert not pattern.fullmatch(prefix + path), prefix + path
for path in ('/p/a/%76%31/retrieve', '/p/a/v1%2fretrieve', '/%70/a/v1/retrieve'):
    assert not pattern.fullmatch(unquote(path)), path
assert labels['traefik.http.routers.headroom-retrieve-deny.rule'] == 'Host(`llm.tapiavala.com`)'
assert labels['traefik.http.middlewares.headroom-public-deny.replacepath.path'] == '/public-denied'
assert int(labels['traefik.http.routers.headroom-retrieve-deny.priority']) < int(labels['traefik.http.routers.headroom.priority']) < int(labels['traefik.http.routers.headroom-mcp.priority'])
print('PASS: model allowlist, project aliases, encoded retrieval bypasses, default deny routing')
