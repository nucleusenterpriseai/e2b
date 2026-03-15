import os
import time

# Set E2B_API_KEY env var before running (sudo cat /opt/e2b/api-key)
assert os.environ.get('E2B_API_KEY'), "E2B_API_KEY not set"

from e2b import Sandbox

print('=== Full E2B Integration Test ===')
print()

# Create sandbox
print('1. Creating sandbox...')
t0 = time.time()
sandbox = Sandbox.create(
    template='base-template',
    api_url='http://localhost:80',
    sandbox_url='http://localhost:5007',
    timeout=300,
    secure=False,
)
t1 = time.time()
print(f'   Created: {sandbox.sandbox_id} in {t1-t0:.2f}s')

# Health check
print('2. Health check...')
print(f'   Running: {sandbox.is_running()}')

# Process execution
print('3. Process execution...')
result = sandbox.commands.run('echo hello from sandbox')
print(f'   stdout: {result.stdout.strip()}')
assert result.stdout.strip() == 'hello from sandbox', f'Expected hello, got: {result.stdout}'

# Multi-command
print('4. Multi-command...')
result = sandbox.commands.run('uname -a')
print(f'   uname: {result.stdout.strip()}')

# Python execution
print('5. Python execution...')
result = sandbox.commands.run('python3 -c "print(2+2)"')
print(f'   python3 2+2 = {result.stdout.strip()}')

# File write/read
print('6. File write...')
sandbox.files.write('/tmp/test.txt', 'hello from e2b!')
print('   Written /tmp/test.txt')

print('7. File read...')
content = sandbox.files.read('/tmp/test.txt')
print(f'   Content: {content}')
assert content == 'hello from e2b!', f'Expected hello, got: {content}'

# List directory
print('8. List directory...')
entries = sandbox.files.list('/tmp')
for e in entries[:5]:
    print(f'   {e.name} ({e.type})')

# Cleanup
print('9. Killing sandbox...')
sandbox.kill()
print('   Done.')

print()
print('=== ALL TESTS PASSED ===')
