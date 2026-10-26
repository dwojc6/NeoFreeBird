#!/usr/bin/env python3
"""Upload a completed IPA to Pixeldrain and emit a correlated, verified receipt."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import zipfile
from urllib.parse import quote
import requests


def main():
    artifact=Path(os.environ['IPA_FILE']).resolve()
    root=Path('main/packages').resolve()
    if artifact.parent!=root or artifact.suffix not in ('.ipa','.tipa') or not artifact.is_file():
        raise ValueError('Expected a built IPA inside main/packages')
    if artifact.name=='com.atebits.Tweetie2.ipa':raise ValueError('Refusing to upload the unmodified source IPA')
    if not zipfile.is_zipfile(artifact):raise ValueError('Built IPA is not a valid ZIP archive')
    key=os.environ.get('PIXELDRAIN_API_KEY','')
    if not key:raise ValueError('Set the repository secret PIXELDRAIN_API_KEY')
    digest=hashlib.sha256()
    with artifact.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
    size=artifact.stat().st_size
    with artifact.open('rb') as stream:
        response=requests.put('https://pixeldrain.com/api/file/'+quote(artifact.name,safe=''),data=stream,auth=('',key),timeout=(15,1800),allow_redirects=False)
    if response.status_code>=300:raise ValueError(f'Pixeldrain upload failed (HTTP {response.status_code})')
    ident=response.json().get('id','')
    if not re.fullmatch(r'[A-Za-z0-9_-]{4,80}',ident):raise ValueError('Invalid Pixeldrain file ID')
    response=requests.get(f'https://pixeldrain.com/api/file/{ident}/info',auth=('',key),timeout=(15,60),allow_redirects=False)
    response.raise_for_status()
    info=response.json()
    if info.get('success') is not True or info.get('hash_sha256')!=digest.hexdigest() or info.get('size')!=size:
        raise ValueError('Pixeldrain checksum/size verification failed')
    url=f'https://pixeldrain.com/api/file/{ident}'
    result={'request_id':os.environ.get('VAULT_REQUEST_ID',''),'run_id':os.environ['GITHUB_RUN_ID'],'file_id':ident,'url':url,'sha256':digest.hexdigest(),'size':size,'filename':artifact.name}
    Path('ipa-vault-result').mkdir(exist_ok=True)
    Path('ipa-vault-result/result.json').write_text(json.dumps(result))
    with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as out:
        out.write(f'\n### Built IPA\n\n[Download from Pixeldrain]({url})\n\nSHA-256: `{digest.hexdigest()}`\n')
    print('Verified IPA uploaded: '+url)

if __name__=='__main__':
    try:main()
    except Exception as error:
        # Do not print request bodies or URLs which might contain credentials.
        print(str(error) if isinstance(error,ValueError) else 'Upload failed; check credentials and provider availability',file=sys.stderr)
        sys.exit(1)
