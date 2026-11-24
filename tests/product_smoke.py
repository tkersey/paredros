import argparse, hashlib, json, os, pathlib, platform, re, signal, subprocess, tempfile, time
parser=argparse.ArgumentParser()
parser.add_argument('binary',type=pathlib.Path)
parser.add_argument('--report',type=pathlib.Path)
parser.add_argument('--essential',action='store_true',help='omit the licenses, version, and offline ask probes')
args=parser.parse_args()
binary=args.binary.resolve(strict=True)
measurements={'startup_to_socket_seconds':[], 'control_seconds':[], 'rss_samples_kib':[]}
results=[]
def run(args, *, config=None, input=None, allowed=(0,), seconds=45):
    command=[str(binary)]
    if config is not None: command += ['--config',str(config)]
    command += args
    started=time.monotonic()
    proc=subprocess.run(command,input=input,text=True,capture_output=True,timeout=seconds)
    if config is not None:
        measurements['control_seconds'].append({'command':args[0], 'seconds':time.monotonic()-started})
    if proc.returncode not in allowed:
        raise AssertionError((args,proc.returncode,proc.stdout,proc.stderr))
    return proc
manifest=json.loads(run(['describe-build']).stdout)
assert manifest['artifact_sha256']==hashlib.sha256(binary.read_bytes()).hexdigest()
expected_backend = {
    ('Linux', 'x86_64'): 'stage2_x86_64',
    ('Darwin', 'arm64'): 'stage2_llvm',
}[(platform.system(), platform.machine())]
assert manifest['artifact_zig_backend'] == expected_backend, manifest['artifact_zig_backend']
c_compiler = manifest['dependencies']['sqlite']['compiler']
assert c_compiler['family'] == 'clang' and c_compiler['driver'] == 'zig build-obj', c_compiler
assert c_compiler['zig_executable_sha256'] == manifest['compiler']['executable_sha256']
for field in ('sqlite_object_sha256', 'posix_shim_object_sha256'):
    assert re.fullmatch(r'[0-9a-f]{64}', c_compiler[field]), field
if not args.essential:
    assert json.loads(run(['licenses']).stdout)['artifact_sha256']==manifest['artifact_sha256']
    assert 'paredros' in run(['--version']).stdout
results.append('embedded manifest and executing artifact hash agree')
with tempfile.TemporaryDirectory(prefix='paredros-smoke-',dir='/tmp') as raw:
    base=pathlib.Path(raw).resolve()
    os.chmod(base,0o700)
    config=base/'config.json'
    value={'version':1,'current_uid':os.geteuid(),'namespace_path':str(base/'state'),
      'control_socket_path':str(base/'control'),
      'repository':{'account':'offline','id':1,'owner':'fixture','name':'repository','ref':'refs/heads/main'}}
    config.write_text(json.dumps(value))
    socket=pathlib.Path(value['control_socket_path'])
    log=open(base/'daemon.log','w+')
    def start():
        started=time.monotonic()
        process=subprocess.Popen([str(binary),'serve','--config',str(config)],stdin=subprocess.DEVNULL,stdout=log,stderr=log)
        deadline=time.monotonic()+40
        while not socket.exists():
            if process.poll() is not None:
                log.flush(); log.seek(0)
                raise AssertionError(('serve failed',process.returncode,log.read()))
            if time.monotonic()>deadline:
                process.terminate(); process.wait(timeout=50)
                raise AssertionError('serve readiness deadline')
            time.sleep(.05)
        measurements['startup_to_socket_seconds'].append(time.monotonic()-started)
        return process
    def stop(process):
        process.send_signal(signal.SIGTERM)
        code=process.wait(timeout=50)
        if code!=0:
            log.flush();log.seek(0)
            raise AssertionError(('shutdown',code,log.read()))
        assert not socket.exists()
    process=start()
    try:
        initial=json.loads(run(['status'],config=config).stdout)
        assert initial['status']=='observed' and initial['data']['obligations']==[]
        def status_namespace_bytes(response):
            observed = int(response['data']['namespace_bytes'])
            expected = sum(file.stat().st_size for file in (base/'state').iterdir())
            assert observed == expected, (observed, expected)
            daemon = response['data']['daemon']
            assert daemon['artifact_sha256'] == manifest['artifact_sha256']
            assert daemon['application_version'] == manifest['application_version']
            return observed
        initial_bytes = status_namespace_bytes(initial)
        command=['monitor','add','--wording','Offline fixture only.','--interval-ms','900000','--operation','smoke-monitor']
        first=json.loads(run(command,config=config).stdout)
        second=json.loads(run(command,config=config).stdout)
        assert first['status']=='admitted' and first['data']['task']==second['data']['task']
        task=first['data']['task']
        deadline=time.monotonic()+30
        while True:
            shown=run(['monitor','show',task],config=config,allowed=(0,1))
            if shown.returncode==0: break
            assert time.monotonic()<deadline,(shown.stdout,shown.stderr)
            time.sleep(.1)
        deadline=time.monotonic()+120
        while True:
            items=json.loads(run(['messages',task],config=config).stdout)['data']['messages']
            if any(item['purpose']=='activation' for item in items): break
            assert time.monotonic()<deadline,items
            time.sleep(.1)
        measurements['rss_samples_kib'].append({'phase':'one_active_offline_monitor','kib':int(subprocess.check_output(['ps','-o','rss=','-p',str(process.pid)],text=True))})
        paused=json.loads(run(['monitor','pause',task,'--operation','smoke-pause'],config=config).stdout)
        assert paused['status']=='admitted'
        request={'version':1,'operation':None,'command':{'tag':'status','value':{'after':None,'limit':16}}}
        invalid={**request,'version':2}
        relay=run(['stdio'],config=config,input=json.dumps(request)+'\n'+json.dumps(invalid)+'\n',allowed=(1,))
        responses=[json.loads(line) for line in relay.stdout.splitlines()]
        assert responses[0]['status']=='observed' and responses[1]['status']=='rejected'
        live={**value,'mode':'live','grants':{'github_read':True,'model':True},
          'github_credential_file':'/definitely-not-present/github',
          'model':{'account':'offline','slug':'fixture-model','effort':'medium','siwc_bin':'/definitely-not-present/siwc','auth_dir':'/definitely-not-present/auth'}}
        live_path=base/'client-only.json';live_path.write_text(json.dumps(live))
        assert json.loads(run(['status'],config=live_path).stdout)['status']=='observed'
        if not args.essential:
            answer_process=subprocess.Popen([str(binary),'--config',str(config),'ask','Explain the offline state.','--target',task,'--operation','smoke-ask'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            started=time.monotonic()
            status_samples=[]
            try:
                while answer_process.poll() is None:
                    if time.monotonic()-started>310: raise AssertionError('ask deadline')
                    measurements['rss_samples_kib'].append({'phase':'offline_ask','kib':int(subprocess.check_output(['ps','-o','rss=','-p',str(process.pid)],text=True))})
                    if len(status_samples)<30:
                        before=time.monotonic()
                        status=json.loads(run(['status'],config=config).stdout)
                        assert status['status']=='observed'
                        status_samples.append(time.monotonic()-before)
                    time.sleep(.1)
                stdout,stderr=answer_process.communicate(timeout=5)
                assert answer_process.returncode in (0,1),(answer_process.returncode,stdout,stderr)
                answer=subprocess.CompletedProcess(answer_process.args,answer_process.returncode,stdout,stderr)
                measurements['ask_with_status_probes_seconds']=time.monotonic()-started
                measurements['status_during_ask_seconds']=status_samples
            finally:
                if answer_process.poll() is None:
                    answer_process.kill()
                    answer_process.wait(timeout=5)
            answer_value=json.loads(answer.stdout)
            assert answer_value['status']=='observed'
            assert answer_value['data']['task_status'] in {'completed','failed','cancelled','waiting_input','parked','blocked','unknown'}
        results.append('offline daemon status, idempotent monitor, local activation message, durable pause, JSON relay'
                       + ('' if args.essential else ', and ask settlement'))
        results.append('client-only live metadata does not read unavailable secrets or execute helper')
    finally:
        stop(process)
    state=base/'state'
    def snapshot():
        return {str(p.relative_to(state)):hashlib.sha256(p.read_bytes()).hexdigest() for p in state.rglob('*') if p.is_file()}
    before=snapshot()
    audited=json.loads(run(['namespace','check'],config=config).stdout)
    after=snapshot()
    assert before==after,('read-only check changed namespace',before.keys(),after.keys())
    assert audited['status']=='audited' and audited['report']['native_closure']['application_readability']=='verified'
    assert audited['report']['native_closure']['continuation_compatibility']=='not_assessed'
    assert audited['report']['tasks']
    assert all(row['disposition'] != 'profile_unresolved' for row in audited['report']['tasks'])
    assert all(row['disposition'] != {'requires_supersession':'image'} for row in audited['report']['tasks']),audited['report']['tasks']
    results.append('SIGTERM joins and parks before teardown; namespace audit leaves all content unchanged')
    process=start()
    try:
        reopened=json.loads(run(['status'],config=config).stdout)
        assert len(reopened['data']['obligations'])==1
        assert status_namespace_bytes(reopened) > initial_bytes
        assert json.loads(run(command,config=config).stdout)['data']['task']==task
        results.append('reopened namespace retains monitor identity and operation retry')
    finally:
        stop(process)
report={'passed':results,'count':len(results),'essential':args.essential,'artifact_sha256':manifest['artifact_sha256'],
        'artifact_zig_backend':manifest['artifact_zig_backend'],'measurements':measurements,'live_services':False}
encoded=json.dumps(report,indent=2)+'\n'
if args.report: args.report.write_text(encoded)
print(encoded,end='')
