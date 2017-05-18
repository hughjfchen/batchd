#!/usr/bin/python

import sys
import os
import getpass
from os.path import isfile, join, dirname
import requests
import json
import yaml
from PyQt4 import QtGui, QtCore

import queuetable
import jobview
import jobedit
import queues as qeditor

APPDIR = dirname(sys.argv[0])

def load_config():
    home = os.environ['HOME']
    homecfg = join(home, ".config", "batchd", "client.yaml")
    cfgfile = None
    if isfile(homecfg):
        cfgfile = open(homecfg, 'r')
    else:
        etc = join("/etc", "batchd", "client.yaml")
        if isfile(etc):
            cfgfile = open(etc, 'r')
    if cfgfile:
        return yaml.load(cfgfile)

def get_manager_url():
    env = os.environ.get('BATCH_MANAGER_URL', None)
    if env:
        return env
    cfg = load_config()
    url = cfg['manager_url']
    if url:
        return url
    return 'http://localhost:9681'

def handle_status(rs):
    if rs.status_code in (401, 403):
        raise InsufficientRightsException(rs.text)
    if rs.status_code != 200:
        raise Exception(rs.text)

def get_job_types(url, settings):
    rs = requests.get(url + "/type", auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    return json.loads(rs.text)

def get_queues(url, settings):
    rs = requests.get(url + "/queue", auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    return json.loads(rs.text)

def do_enqueue(url, settings, qname, typename, params):
    rq = dict(queue = qname, type=typename, params=params)
    rs = requests.post(url+ "/queue/" + qname, data=json.dumps(rq), auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    print(rs.text)

def get_queue_stats(url, settings, qname):
    rs = requests.get(url + "/stats/" + qname, auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    return json.loads(rs.text)

def get_jobs(url, settings, qname):
    rs = requests.get(url + "/queue/" + qname + "/jobs?status=all", auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    return json.loads(rs.text)

def delete_job(url, settings, jobid):
    rs = requests.delete(url + "/job/" + str(jobid), auth=settings.credentials, verify=settings.verify, cert=settings.client_certificate)
    handle_status(rs)
    print rs

def labelled(label, constructor, parent=None):
    result = QtGui.QWidget(parent)
    layout = QtGui.QHBoxLayout()
    result.setLayout(layout)
    lbl = QtGui.QLabel(label)
    layout.addWidget(lbl)
    widget = constructor(result)
    layout.addWidget(widget)
    return result, widget

def get_icon(name):
    path = join(APPDIR, "icons", name)
    return QtGui.QIcon(path)

class InsufficientRightsException(Exception):
    pass

class ConnectSettings(object):
    def __init__(self, username, password):
        self.username = username
        self.password = password
        self.key = None
        self.certificate = None
        self.ca_certificate = None

    @property
    def credentials(self):
        return (self.username, self.password)

    @property
    def client_certificate(self):
        if self.key and self.certificate:
            return (self.certificate, self.key)
        else:
            return None

    @property
    def verify(self):
        if self.ca_certificate:
            return self.ca_certificate
        else:
            return False
    
class LoginBox(QtGui.QDialog):
    def __init__(self, url, parent=None):
        QtGui.QDialog.__init__(self, parent)

        self.url = url
        self.settings = None

        self.config = cfg = load_config()

        form = QtGui.QFormLayout()
        vbox = QtGui.QVBoxLayout()
        self.setLayout(vbox)
        self.login = QtGui.QLineEdit(self)
        if 'username' in cfg:
            username = cfg['username']
        else:
            username = getpass.getuser()
        self.login.setText(username)
        self.password = QtGui.QLineEdit(self)
        self.password.setEchoMode(QtGui.QLineEdit.Password)
        if 'password' in cfg:
            self.password.setText(cfg['password'])
        form.addRow("User name:", self.login)
        form.addRow("Password:", self.password)
        vbox.addLayout(form)
        bbox = QtGui.QDialogButtonBox(self)
        ok = QtGui.QPushButton('Ok')
        ok.clicked.connect(self.on_ok)
        cancel = QtGui.QPushButton('Cancel')
        cancel.clicked.connect(self.on_cancel)
        bbox.addButton(ok, QtGui.QDialogButtonBox.AcceptRole)
        bbox.addButton(cancel, QtGui.QDialogButtonBox.RejectRole)
        vbox.addWidget(bbox)
        self.setAttribute(QtCore.Qt.WA_DeleteOnClose)

    def on_ok(self):
        try:
            settings = ConnectSettings(self.login.text(), self.password.text())
            settings.certificate = self.config.get('certificate', None)
            settings.key = self.config.get('key', None)
            settings.ca_certificate = self.config.get('ca_certificate', None)
            get_queues(self.url, settings)
            self.settings = settings
            self.accept()
        except InsufficientRightsException as e:
            print e

    def on_cancel(self):
        self.settings = None
        self.reject()

class GUI(QtGui.QMainWindow):
    def __init__(self, url, settings):
        QtGui.QMainWindow.__init__(self)

        self.url = url
        self.settings = settings

        central_widget = QtGui.QWidget(self)

        self.layout = QtGui.QVBoxLayout()
        central_widget.setLayout(self.layout)

        self.setCentralWidget(central_widget)

        wrapper = QtGui.QWidget(self)
        hbox = QtGui.QHBoxLayout()
        wrapper.setLayout(hbox)
        lbl = QtGui.QLabel("Queue:", wrapper)
        hbox.addWidget(lbl)
        self.queue_popup = QtGui.QComboBox(wrapper)
        hbox.addWidget(self.queue_popup, stretch=1)

        self._fill_queues()
        self.queue_popup.currentIndexChanged.connect(self._on_select_queue)
        self.layout.addWidget(wrapper)

        queue_buttons = QtGui.QToolBar(self)
        queue_buttons.addAction(get_icon("list-add.svg"), "New queue", self._on_add_queue)
        self.enable_queue = QtGui.QAction(get_icon("checkbox.svg"), "Enable", self)
        self.enable_queue.setCheckable(True)
        self.enable_queue.toggled.connect(self._on_queue_toggle)
        queue_buttons.addAction(self.enable_queue)
        hbox.addWidget(queue_buttons)

        self.queue_info = QtGui.QLabel(self)
        self.layout.addWidget(self.queue_info)

        buttons = QtGui.QToolBar(self)
        buttons.addAction(get_icon("quickview.svg"), "View", self._on_view)
        buttons.addAction(get_icon("edit-delete.svg"), "Delete", self._on_delete)
        self.layout.addWidget(buttons)

        self.qtable = queuetable.Table(parent=self)
        self.layout.addWidget(self.qtable)

        wrapper, self.type_popup = labelled("Job type:", QtGui.QComboBox, self)
        self.types = types = get_job_types(self.url, self.settings)
        self.type_by_name = {}
        for t in types:
            name = t['name']
            title = t.get('title', name)
            if not title:
                title = name
            item = QtGui.QStandardItem(name)
            item.setData(title, QtCore.Qt.DisplayRole)
            self.type_popup.model().appendRow(item)
            self.type_by_name[name] = t
        self.type_popup.currentIndexChanged.connect(self._on_select_type)
        self.layout.addWidget(wrapper)

        ok = QtGui.QPushButton(get_icon("list-add.svg"), "Add", self)
        ok.clicked.connect(self._on_ok)
        self.layout.addWidget(ok)

        self.param_widgets = {}
        self.form = None

        self._on_select_type(0)
        self._on_select_queue(0)

        timer = QtCore.QTimer(self)
        timer.timeout.connect(self._on_timer)
        timer.start(5*1000)

    def _fill_queues(self):
        self.queue_popup.clear()
        self.queues = queues = get_queues(self.url, self.settings)
        for q in queues:
            enabled = "*" if q['enabled'] else " "
            title = "[{0}] {1}".format(enabled, q['title'])
            self.queue_popup.addItem(title, q['name'])

    def _on_view(self):
        job = self.qtable.currentJob()
        jobtype = self.type_by_name[job['type']]
        dlg = jobview.JobView(job, jobtype, parent=self)
        dlg.exec_()

    def _on_queue_toggle(self):
        enabled = self.enable_queue.isChecked()
        print enabled

    def _on_delete(self):
        buttons = QtGui.QMessageBox.Yes | QtGui.QMessageBox.No
        job = self.qtable.currentJob()
        job_id = job['id']
        ok = QtGui.QMessageBox.question(self, "Delete?",
                                        "Are you really sure you want to delete job #{}?".format(job_id),
                                        buttons)
        if ok == QtGui.QMessageBox.Yes:
            print "Deleting!"
            delete_job(self.url, self.settings, job_id)
            self._refresh_queue()
        else:
            print "do not delete"

    def _on_select_type(self, idx):
        jobtype = self.types[idx]
        self.param_widgets = {}
        form = jobedit.create_form(jobtype['params'], self.param_widgets, self)

        if self.form:
            self.form.hide()
            self.layout.removeWidget(self.form)
            del self.form
        self.form = form
        self.layout.insertWidget(5, form)
        self.form.show()

    def _on_add_queue(self):
        dlg = qeditor.QueueEditor(self)
        dlg.exec_()
        self._fill_queues()

    def _on_select_queue(self, idx):
        self._refresh_queue(idx)

    def _on_timer(self):
        self._refresh_queue()

    def _refresh_queue(self, idx=None):
        if idx is None:
            idx = self.queue_popup.currentIndex()

        if len(self.queues) == 0:
            print("No queues.")
            return

        queue = self.queues[idx]
        schedule = queue['schedule_name']
        host = queue['host_name']
        if not host:
            host = "*"
        stats = get_queue_stats(self.url, self.settings, queue['name'])
        new = stats.get('new', 0)
        processing = stats.get('processing', 0)
        done = stats.get('done', 0)
        failed = stats.get('failed', 0)
        info = "Schedule: {}\nHost: {}\nNew/Processing/Done: {} / {} / {}\nFailed: {}".format(schedule, host, new, processing, done, failed)
        self.queue_info.setText(info)
        self.enable_queue.setChecked(queue['enabled'])

        jobs = get_jobs(self.url, self.settings, queue['name'])
        self.qtable.setJobs(jobs)

    def _on_ok(self):
        queue_idx = self.queue_popup.currentIndex()
        queue_name = self.queues[queue_idx]['name']
        #typename = unicode( self.type_popup.currentText() )
        jobtype = self.types[self.type_popup.currentIndex()]
        typename = jobtype['name']
        params = {}
        for name, widget in self.param_widgets.iteritems():
            params[name] = unicode(widget.text())
        do_enqueue(self.url, self.settings, queue_name, typename, params)
        self._refresh_queue()

    def get_schedules(self):
        rs = requests.get(self.url + "/schedule", auth=self.settings.credentials, verify=settings.verify, cert=settings.client_certificate)
        handle_status(rs)
        return json.loads(rs.text)

    def new_queue(self, queue):
        rs = requests.post(self.url + "/queue", data=json.dumps(queue), auth=self.settings.credentials, verify=settings.verify, cert=settings.client_certificate)
        handle_status(rs)
        print(rs.text)


if __name__ == "__main__":
    app = QtGui.QApplication(sys.argv)
    URL = get_manager_url()
    login_box = LoginBox(URL)
    if login_box.exec_():
        settings = login_box.settings
        gui = GUI(URL, settings)
        gui.show()
        sys.exit(app.exec_())

