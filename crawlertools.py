import requests
import os
import hashlib


def get_image(url, path='', overwrite=0, hash=False): # overwrite 0 - skip, 1 - rename, 2 - overwrite
    try:
        s = requests.get(url)
    except Exception as e:
        print("Couldn't get image "+url)
        print(e)
        return
    try:
        filename = s.headers.get('Content-Disposition').replace('filename=', '', 1)
    except:
        filename = url.rsplit('/')[-1]
    try:
        filename, format = filename.rsplit('.')
        format = '.'+format
    except:
        format = ''
    try:
        if path and not os.path.exists(path):
            os.makedirs(path)
    except:
        pass
    if hash:
        filename = hashlib.md5(s.content).hexdigest()
    if overwrite == 0:
        if os.path.exists(os.path.join(path, filename+format)):
            print(filename+format+' exists, skipped.')
            return
    elif overwrite == 1:
        original_filename = filename
        num = 2
        while os.path.exists(os.path.join(path, filename+format)):
            filename = original_filename+' ('+str(num)+')'
            num += 1
    try:
        with open(os.path.join(path, filename+format), 'wb') as f:
            f.write(s.content)
    except Exception as e:
        print("Couldn't get "+os.path.join(path, filename+format)+" : "+str(e))
    print('Saved '+url+' as '+filename+format)
