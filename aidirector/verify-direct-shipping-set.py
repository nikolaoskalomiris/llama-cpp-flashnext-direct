#!/usr/bin/env python3
import argparse, hashlib, json, re, subprocess, sys
from pathlib import Path

HEX64 = re.compile(r"^[0-9A-F]{64}$")

def sha256_file(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):
            h.update(chunk)
    return h.hexdigest().upper()

def load_contract(path: Path) -> dict:
    c=json.loads(path.read_text(encoding='utf-8'))
    if c.get('schema')!='ai-director-direct-build-contract/v1':
        raise ValueError('Unexpected contract schema')
    ss=c.get('shipping_set') or []
    if len(ss)!=17:
        raise ValueError(f'Expected 17 shipping entries, got {len(ss)}')
    names=[x.get('name') for x in ss]
    if len(names)!=len(set(names)):
        raise ValueError('Duplicate shipping names in contract')
    for x in ss:
        h=str(x.get('accepted_historical_sha256','')).upper()
        if not HEX64.fullmatch(h):
            raise ValueError(f"Invalid accepted SHA-256 for {x.get('name')}")
    tools=((c.get('reference_toolchain') or {}).get('tools') or {})
    required={'cmake.exe','ninja.exe','cl.exe','link.exe','lib.exe','vcvars64.bat','rc.exe','mt.exe','nvcc.exe','cicc.exe','ptxas.exe','fatbinary.exe','nvlink.exe','nvcc.profile'}
    if set(tools)!=required:
        raise ValueError(f'Tool key set mismatch: {sorted(set(tools)^required)}')
    for name,rec in tools.items():
        if not HEX64.fullmatch(str(rec.get('sha256','')).upper()):
            raise ValueError(f'Invalid tool SHA-256: {name}')
    if ((c.get('configure') or {}).get('cache') or {}).get('LLAMA_BUILD_UI')!='OFF':
        raise ValueError('LLAMA_BUILD_UI must be OFF')
    if ((c.get('configure') or {}).get('cache') or {}).get('LLAMA_USE_PREBUILT_UI')!='OFF':
        raise ValueError('LLAMA_USE_PREBUILT_UI must be OFF')
    if 'CMAKE_CUDA_ARCHITECTURES' not in ((c.get('configure') or {}).get('must_be_absent_from_cache') or []):
        raise ValueError('CMAKE_CUDA_ARCHITECTURES absence is not enforced')
    if (c.get('configure') or {}).get('ccache_executable_policy') != 'ABSENT':
        raise ValueError('Reference contract must require the ccache executable to be absent')
    tools=((c.get('reference_toolchain') or {}).get('tools') or {})
    for name in ('cl.exe','link.exe','lib.exe','rc.exe','mt.exe'):
        if name not in tools:
            raise ValueError(f'Missing bound reference tool: {name}')
    required=set((c.get('reference_toolchain') or {}).get('vcvars_resolution_must_match') or [])
    if required != {'cl.exe','link.exe','lib.exe','rc.exe','mt.exe'}:
        raise ValueError('vcvars resolution binding set is incomplete')
    policy=c.get('repository_automation_policy') or {}
    active=policy.get('active_workflows') or []
    if active != ['.github/workflows/aidirector-direct-contract.yml']:
        raise ValueError('Direct repository must declare exactly the AI Director contract workflow as active')
    if int(policy.get('active_workflow_count',0)) != 1:
        raise ValueError('Direct repository active workflow count must be 1')
    if int(policy.get('retired_upstream_workflow_count',-1)) != 52:
        raise ValueError('Retired upstream workflow count must be 52')
    if policy.get('retired_upstream_workflow_manifest') != 'aidirector/retired-upstream-workflows-v1.json':
        raise ValueError('Retired workflow manifest path mismatch')
    return c

def check_overlay(repo: Path, contract: dict) -> dict:
    baseline=contract['source_baseline']['commit']
    allowed=set(contract['source_baseline']['allowed_overlay_paths'])
    def git(*args):
        cp=subprocess.run(['git','-C',str(repo),*args],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        if cp.returncode:
            raise RuntimeError(cp.stderr.strip() or 'git failed')
        return cp.stdout.strip()
    head=git('rev-parse','HEAD')
    subprocess.run(['git','-C',str(repo),'merge-base','--is-ancestor',baseline,'HEAD'],check=True)
    changed=[x for x in git('diff','--name-only',f'{baseline}..HEAD').splitlines() if x]
    unexpected=[x for x in changed if x not in allowed]
    return {'head':head,'changed':changed,'unexpected':unexpected}

def check_workflow_surface(repo: Path, contract: dict) -> dict:
    policy=contract['repository_automation_policy']
    expected=set(policy['active_workflows'])
    workflow_dir=repo/'.github'/'workflows'
    if not workflow_dir.is_dir():
        raise RuntimeError('Workflow directory is missing')
    actual={str(p.relative_to(repo)).replace('\\','/') for p in workflow_dir.iterdir() if p.is_file()}
    missing=sorted(expected-actual); unexpected=sorted(actual-expected)
    return {'expected':sorted(expected),'actual':sorted(actual),'missing':missing,'unexpected':unexpected}

def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('--contract',type=Path,default=Path(__file__).with_name('direct-build-contract-v1.json'))
    ap.add_argument('--shipping-dir',type=Path)
    ap.add_argument('--report',type=Path)
    ap.add_argument('--require-accepted-hashes',action='store_true')
    ap.add_argument('--contract-only',action='store_true')
    ap.add_argument('--repo-root',type=Path)
    ns=ap.parse_args()
    c=load_contract(ns.contract)
    result={'schema':'ai-director-direct-shipping-verification/v1','contract_sha256':sha256_file(ns.contract),'contract_valid':True}
    if ns.repo_root:
        ov=check_overlay(ns.repo_root,c); result['overlay']=ov
        if ov['unexpected']:
            raise RuntimeError('Unexpected source drift: '+', '.join(ov['unexpected']))
        wf=check_workflow_surface(ns.repo_root,c); result['workflow_surface']=wf
        if wf['missing'] or wf['unexpected']:
            raise RuntimeError('Workflow surface mismatch; missing='+str(wf['missing'])+'; unexpected='+str(wf['unexpected']))
    if ns.contract_only:
        print('DIRECT_CONTRACT_VALIDATION=PASS')
        print('SHIPPING_SET_ENTRIES=17')
        print('CMAKE_CUDA_ARCHITECTURES_POLICY=UNSET')
        print('UI_PROVISIONING=OFF')
        if ns.repo_root:
            print('WORKFLOW_SURFACE=PASS_EXACT_1_ACTIVE')
        return 0
    if not ns.shipping_dir:
        ap.error('--shipping-dir is required unless --contract-only is used')
    d=ns.shipping_dir
    expected={x['name']:x['accepted_historical_sha256'].upper() for x in c['shipping_set']}
    files={p.name:p for p in d.iterdir() if p.is_file()}
    if set(files)!=set(expected):
        missing=sorted(set(expected)-set(files)); extra=sorted(set(files)-set(expected))
        raise RuntimeError(f'Shipping set mismatch; missing={missing}; extra={extra}')
    recs=[]; accepted=0
    for name in sorted(expected):
        p=files[name]; h=sha256_file(p); match=h==expected[name]; accepted+=int(match)
        recs.append({'name':name,'bytes':p.stat().st_size,'sha256':h,'accepted_historical_sha256':expected[name],'accepted_historical_match':match})
    result['files']=recs; result['file_count']=len(recs); result['accepted_historical_hash_matches']=accepted
    result['identity_interpretation']='Accepted historical hashes are authority references. A local/custom build remains non-official unless separately accepted and promoted.'
    if ns.require_accepted_hashes and accepted!=len(recs):
        raise RuntimeError(f'Accepted-hash mode requested but only {accepted}/{len(recs)} files match')
    if ns.report:
        ns.report.parent.mkdir(parents=True,exist_ok=True)
        ns.report.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print('DIRECT_SHIPPING_SET=PASS')
    print(f'SHIPPING_FILES={len(recs)}')
    print(f'ACCEPTED_HISTORICAL_HASH_MATCHES={accepted}/{len(recs)}')
    print('OFFICIAL_ACCEPTED_REPLACEMENT_AUTHORIZED=NO')
    return 0

if __name__=='__main__':
    try:
        raise SystemExit(main())
    except Exception as e:
        print(f'DIRECT_SHIPPING_SET=ERROR\nERROR={e}',file=sys.stderr)
        raise
