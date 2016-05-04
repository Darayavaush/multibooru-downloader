import threading
# from grab import Grab
import requests
import crawlertools
import itertools
import re
import queue
import subprocess
import os
import lxml.html as lxml_html
import time
from lxml import etree
import argparse


class Site:

    filename_format = '%o %h'

    def lxmlify(self, url, attempts=1):
        for _ in range(attempts):
            try:
                r = self.s.get(url)
                break
            except Exception as e:
                time.sleep(3)
        return lxml_html.fromstring(r.text)

    def authorize(self, login, password, cookie):
        print('Authorization skipped.')

    def next_page(self):
        raise NotImplementedError

    def handle_page(self, layer, inp):
        raise NotImplementedError

    def get_image(self, url, silent=False):
        return crawlertools.get_image(url, self.path, 0, silent=silent, session=self.s, name=self.filename_format)

    def _worker(self):
        while True:
            inp = self.work.get()
            if not inp:
                break
            print('Got '+str(inp)+' from queue.')
            if inp[0] == -1:
                self.get_image(inp[1])
            else:
                self.handle_page(inp[0], inp[1])
            self.work.task_done()

    def _overseer(self):
        for _ in range(30):
            t = threading.Thread(target=self._worker)
            t.daemon = True
            t.start()
        self.work.join()

    def make_subpath(self, format=None):
        return self.input

    def __init__(self, inp='', login='', password='', cookie='', path=''):
        self.work = queue.Queue()
        self.s = requests.session()
        self.authorize(login, password, cookie)
        if not inp:
            print('No input detected.')
            return
        else:
            self.input = inp
            print('Input: '+self.input)
        self.path = os.path.join(path, self.make_subpath())
        self.path = os.path.abspath(self.path)
        try: os.mkdir(self.path)
        except: pass
        print('Getting image list…')
        self.n = self.next_page()
        self.work.put((0, next(self.n)))
        # threading.Thread(target=self._overseer).start()
        for _ in range(40):
            threading.Thread(target=self._worker).start()
        self.work.join()
        for _ in range(threading.active_count()):
            self.work.put(None)
        print(self.input+' done.')

class DA(Site):

    def next_page(self, page):
        return 'http://'+self.input+'.deviantart.com/gallery/?offset='+str(page*24)

    def authorize(self, login, password):
        self.br.open('https://www.deviantart.com/users/login')
        login_form = self.br.get_form('login')
        login_form['username'].value = login
        login_form['password'].value = password
        self.br.submit_form(login_form)

    def handle_page(self):
        images = [x.parent for x in self.br.select('#gmi-ResourceStream img')]
        if not images:
            return 1
        for x in images:
            try:
                self.images.append(x['data-super-full-img'])
                continue
            except:
                pass
            try:
                self.images.append(x['data-super-img'])
                continue
            except:
                pass
            try:
                self.br.open(x['href'])
                self.images.append(self.br.select('.dev-view-deviation img:not(.avatar)')[0]['src'])
                continue
            except:
                pass
            try:
                print('Failed to get '+x['href']+', probably a Flash.')
            except:
                print('Failed to do anything with '+str(x))
        # return 0

class Pixiv(Site):

    ugoira_path = 'S:/Ugoiras/pixanim.rb'

    @staticmethod
    def originalify(src):
        src = src.replace('_master1200', '')
        src = re.sub('c/(\d+)x(\d+)/img-master',  'img-original', src)
        return src

    def authorize(self, login, password, cookie):
        if not cookie:
            raise Exception('Pixiv requires a cookie.')
        self.s.headers = {'Referer': 'http://pixiv.net/'}
        self.s.cookies.set('PHPSESSID', cookie)

    def next_page(self):
        for page in itertools.count():
            yield 'http://www.pixiv.net/member_illust.php?id='+self.input+'&type=all&p='+str(page+1)

    def make_subpath(self, format='%b/%p (%i)'):
        if not format:
            return self.input
        format = format.split('/')
        for part in format:
            try:
                if '%b' in part:
                    lx = etree.fromstring(requests.get('http://danbooru.donmai.us/artists.xml?name=http://www.pixiv.net/member.php?id='+self.input).text. encode())
                    artist_name = lx.findall('.//name')[0].text
                    part = part.replace('%b', artist_name)
                if '%p' in part:
                    lx = self.lxmlify('http://www.pixiv.net/member.php?id='+self.input)
                    pixiv_name = lx.xpath('//*[@class="user"]')[0].text
                    part = part.replace('%p', pixiv_name)
                if '%i' in part:
                    part = part.replace('%i', self.input)

                part = part.title().replace('_', ' ')
                return part
            except Exception as e:
                # print(e)
                pass
        raise Exception('Failed to make subpath.')

    def handle_page(self, layer, url):
        if layer == 0:
            lx = self.lxmlify(url, attempts=5)
            works = lx.xpath('//a[contains(@class,"work ")]')
            if len(works) == 20:
                self.work.put((0, next(self.n)))
            for x in works:
                if 'multiple' in x.get('class'):  # manga
                    link = x.get('href')
                    self.work.put((2, link))
                elif 'ugoku-illust' in x.get('class'):  # ugoira
                    continue  # fuck this
                    image_id = x['href'].rsplit('=', 1)[1]
                    os.chdir(self.path)
                    subprocess.call("ruby "+self.ugoira_path+" "+image_id)
                    print('Ugoira saved')
                else:  # normal image
                    src = x.xpath('.//img')[0].get('src')
                    src = self.originalify(src)
                    self.work.put((1, src))
        elif layer == 1:
            if self.get_image(url, silent=True) == 1:
                if self.get_image(url.replace('jpg', 'png')) == 1:
                    if self.get_image(url) == 1:
                        if self.get_image(url.replace('jpg', 'png')) == 1:
                            if self.get_image(url.replace('jpg', 'gif')) == 1:
                                self.get_image(url.replace('jpg', 'gif'))
        elif layer == 2:
            lx = self.lxmlify('http://pixiv.net'+url, attempts=5)
            pages = re.search(': (\d+)P', lx.xpath('//ul[@class="meta"]/li/text()')[1]).group(1)
            src = lx.xpath('//div[@class="_layout-thumbnail"]/img')[0].get('src')
            base_src = self.originalify(src)
            for x in range(int(pages)):
                src = base_src.replace('p0', 'p'+str(x))
                self.work.put((1, src))

parser = argparse.ArgumentParser()
parser.add_argument('site')
parser.add_argument('input', nargs='?')
parser.add_argument('-l', '--login')
parser.add_argument('-p', '--password')
parser.add_argument('-c', '--cookie')
parser.add_argument('-d', '--directory')
try:
    args = parser.parse_args()
    globals()[args.site](inp=args.input, login=args.login, password=args.password, cookie=args.cookie, path=args.directory)
except:
    pass

