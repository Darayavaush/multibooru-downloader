import threading
from robobrowser import RoboBrowser
import crawlertools
import itertools
from concurrent.futures import ThreadPoolExecutor as Pool


class Site:

    def authorize(self, login, password):
        print('Authorization skipped.')

    def make_url(self, url):
        raise NotImplementedError

    def handle_page(self):
        raise NotImplementedError

    def get_image(self, url):
        crawlertools.get_image(url, self.path, 0)

    def __init__(self, inp, login='', password='', path=0):
        self.path = path or inp
        self.images = []
        self.input = inp
        self.br = RoboBrowser()
        print('Authorizing…')
        self.authorize(login, password)
        print('Getting image list…')
        for page in itertools.count():
            url = self.make_url(page)
            print('Getting page '+str(page)+', url '+url)
            self.br.open(url)
            exit_code = self.handle_page()
            if exit_code:
                break
        with Pool(max_workers=8) as executor:
            executor.map(self.get_image, self.images)


class DA(Site):

    def make_url(self, page):
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
        return 0


# DA('yuni', 'name', 'pass')