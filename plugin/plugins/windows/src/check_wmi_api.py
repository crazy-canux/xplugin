#!/usr/bin/env python
# -*- coding: utf-8 -*-

"""Copyright (C) Canux CHENG <canuxcheng@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

import sys
import datetime
import logging
import argparse
import csv
import subprocess


class Monitor(object):

    """Basic class for monitor.

    Nagios and tools based on nagios have the same status.
    All tools have the same output except check_mk.

        Services Status:
        0 green  OK
        1 yellow Warning
        2 red    Critical
        3 orange Unknown
        * grey   Pending

        Nagios Output(just support 4kb data):
        shortoutput - $SERVICEOUTPUT$
        -> The first line of text output from the last service check.

        perfdata - $SERVICEPERFDATA$
        -> Contain any performance data returned by the last service check.
        With format: | 'label'=value[UOM];[warn];[crit];[min];[max].

        longoutput - $LONGSERVICEOUTPUT$
        -> The full text output aside from the first line from the last service check.

        example:
        OK - shortoutput. |
        Longoutput line1
        Longoutput line2 |
        'perfdata'=value[UOM];[warn];[crit];[min];[max]
    """

    def __init__(self):
        # Init the log.
        logging.basicConfig(format='[%(levelname)s] (%(module)s) %(message)s')
        self.logger = logging.getLogger("monitor")
        self.logger.setLevel(logging.INFO)

        # Init output data.
        self.nagios_output = ""
        self.shortoutput = ""
        self.perfdata = []
        self.longoutput = []

        # Init the argument
        self.__define_options()
        self.define_sub_options()
        self.__parse_options()

        # Init the logger
        if self.args.debug:
            self.logger.setLevel(logging.DEBUG)
        self.logger.debug("===== BEGIN DEBUG =====")
        self.logger.debug("Init Monitor")

        # End the debug.
        if self.__class__.__name__ == "Monitor":
            self.logger.debug("===== END DEBUG =====")

    def __define_options(self):
        self.parser = argparse.ArgumentParser(description="Plugin for Monitor.")
        self.parser.add_argument('-D', '--debug',
                                 action='store_true',
                                 required=False,
                                 help='Show debug informations.',
                                 dest='debug')

    def define_sub_options(self):
        """Define options for monitoring plugins.

        Rewrite your method and define your suparsers.
        Use subparsers.add_parser to create sub options for one function.
        """
        self.plugin_parser = self.parser.add_argument_group("Plugin Options",
                                                            "Options for all plugins.")
        self.plugin_parser.add_argument("-H", "--host",
                                        default='127.0.0.1',
                                        required=True,
                                        help="Use host IP address not DNS",
                                        dest="host")
        self.plugin_parser.add_argument("-u", "--user",
                                        default=None,
                                        required=False,
                                        help="User name",
                                        dest="user")
        self.plugin_parser.add_argument("-p", "--password",
                                        default=None,
                                        required=False,
                                        help="User password",
                                        dest="password")

    def __parse_options(self):
        try:
            self.args = self.parser.parse_args()
        except Exception as e:
            self.unknown("Parser arguments error: {}".format(e))

    def output(self, substitute=None, long_output_limit=None):
        """Just for nagios output and tools based on nagios except check_mk.

        Default longoutput show everything.
        But you can use long_output_limit to limit the longoutput lines.
        """
        if not substitute:
            substitute = {}

        self.nagios_output += "{0}".format(self.shortoutput)
        if self.longoutput:
            self.nagios_output = self.nagios_output.rstrip("\n")
            self.nagios_output += " | \n{0}".format(
                "\n".join(self.longoutput[:long_output_limit]))
            if long_output_limit:
                self.nagios_output += "\n(...showing only first {0} lines, " \
                    "{1} elements remaining...)".format(
                        long_output_limit,
                        len(self.longoutput[long_output_limit:]))
        if self.perfdata:
            self.nagios_output = self.nagios_output.rstrip("\n")
            self.nagios_output += " | \n{0}".format(" ".join(self.perfdata))
        return self.nagios_output.format(**substitute)

    def ok(self, msg):
        raise MonitorOk(msg)

    def warning(self, msg):
        raise MonitorWarning(msg)

    def critical(self, msg):
        raise MonitorCritical(msg)

    def unknown(self, msg):
        raise MonitorUnknown(msg)


class MonitorOk(Exception):

    def __init__(self, msg):
        print("OK - %s" % msg)
        raise SystemExit(0)


class MonitorWarning(Exception):

    def __init__(self, msg):
        print("WARNING - %s" % msg)
        raise SystemExit(1)


class MonitorCritical(Exception):

    def __init__(self, msg):
        print("CRITICAL - %s" % msg)
        raise SystemExit(2)


class MonitorUnknown(Exception):

    def __init__(self, msg):
        print("UNKNOWN - %s" % msg)
        raise SystemExit(3)


class Wmi(Monitor):

    """Basic class for wmi."""

    def __init__(self):
        super(Wmi, self).__init__()
        self.logger.debug("Init Wmi")

    def query(self, wql):
        """Connect by wmi and run wql."""
        try:
            self.__wql = ['wmic', '-U',
                          self.args.domain + '\\' + self.args.user + '%' + self.args.password,
                          '//' + self.args.host,
                          '--namespace', self.args.namespace,
                          '--delimiter', self.args.delimiter,
                          wql]
            self.logger.debug("wql: {}".format(self.__wql))
            self.__output = subprocess.check_output(self.__wql)
            self.logger.debug("output: {}".format(self.__output))
            self.logger.debug("wmi connect succeed.")
            self.__wmi_output = self.__output.splitlines()[1:]
            self.logger.debug("wmi_output: {}".format(self.__wmi_output))
            self.__csv_header = csv.DictReader(self.__wmi_output, delimiter='|')
            self.logger.debug("csv_header: {}".format(self.__csv_header))
            return list(self.__csv_header)
        except subprocess.CalledProcessError as e:
            self.unknown("Connect by wmi and run wql error: %s" % e)

    def define_sub_options(self):
        super(Wmi, self).define_sub_options()
        self.wmi_parser = self.parser.add_argument_group("WMI Options",
                                                         "options for WMI connect.")
        self.subparsers = self.parser.add_subparsers(title="WMI Action",
                                                     description="Action mode for WMI.",
                                                     help="Specify your action for WMI.")
        self.wmi_parser.add_argument('-d', '--domain',
                                     required=False,
                                     help='wmi server domain.',
                                     dest='domain')
        self.wmi_parser.add_argument('--namespace',
                                     default='root\cimv2',
                                     required=False,
                                     help='namespace for wmi, default is %(default)s',
                                     dest='namespace')
        self.wmi_parser.add_argument('--delimiter',
                                     default='|',
                                     required=False,
                                     help='delimiter for wmi, default is %(default)s',
                                     dest='delimiter')


class FileNumber(Wmi):

    r"""Count the number of file in the folder."""

    def __init__(self):
        super(FileNumber, self).__init__()
        self.logger.debug("Init FileNumber")

    def define_sub_options(self):
        super(FileNumber, self).define_sub_options()
        self.fn_parser = self.subparsers.add_parser('filenumber',
                                                    help='Count file number.',
                                                    description='Options\
                                                    for filenumber.')
        self.fn_parser.add_argument('-q', '--query',
                                    required=False,
                                    help='wql for wmi.',
                                    dest='query')
        self.fn_parser.add_argument('-d', '--drive',
                                    required=True,
                                    help='the windows driver, like C:',
                                    dest='drive')
        self.fn_parser.add_argument('-p', '--path',
                                    default="\\\\",
                                    required=False,
                                    help='the folder, default is %(default)s',
                                    dest='path')
        self.fn_parser.add_argument('-f', '--filename',
                                    default="%%",
                                    required=False,
                                    help='the filename, default is %(default)s',
                                    dest='filename')
        self.fn_parser.add_argument('-e', '--extension',
                                    default="%%",
                                    required=False,
                                    help='the file extension, default is %(default)s',
                                    dest='extension')
        self.fn_parser.add_argument('-R', '--recursion',
                                    action='store_true',
                                    help='Recursive count file under path.',
                                    dest='recursion')
        self.fn_parser.add_argument('-w', '--warning',
                                    default=0,
                                    type=int,
                                    required=False,
                                    help='Warning number of file, default is %(default)s',
                                    dest='warning')
        self.fn_parser.add_argument('-c', '--critical',
                                    default=0,
                                    type=int,
                                    required=False,
                                    help='Critical number of file, default is %(default)s',
                                    dest='critical')

    def __get_file(self, path):
        self.wql_file = "SELECT Name FROM CIM_DataFile WHERE Drive='{0}' \
            AND Path='{1}' AND FileName LIKE '{2}' AND Extension LIKE '{3}'".format(self.args.drive,
                                                                                    path,
                                                                                    self.args.filename,
                                                                                    self.args.extension)
        self.file_data = self.query(self.wql_file)
        [self.file_list.append(file_data) for file_data in self.file_data]
        self.logger.debug("file_data: {}".format(self.file_data))
        return len(self.file_data), self.file_list

    def __get_folder(self, path):
        self.wql_folder = "SELECT FileName FROM CIM_Directory WHERE Drive='{0}' AND Path='{1}'".format(self.args.drive,
                                                                                                       path)
        self.number, self.file_list = self.__get_file(path)
        self.count += self.number
        self.folder_data = self.query(self.wql_folder)
        self.logger.debug("folder_data: {}".format(self.folder_data))
        if self.folder_data:
            for folder in self.folder_data:
                self.new_path = (folder['Name'].split(":")[1] + "\\").replace("\\", "\\\\")
                self.__get_folder(self.new_path)
        return self.count, self.file_list

    def filenumber_handle(self):
        """Get the number of file in the folder."""
        self.file_list = []
        self.count = 0
        status = self.ok

        if self.args.recursion:
            self.__result, self.__file_list = self.__get_folder(self.args.path)
        else:
            self.__result, self.__file_list = self.__get_file(self.args.path)

        # Compare the vlaue.
        if self.__result > self.args.critical:
            status = self.critical
        elif self.__result > self.args.warning:
            status = self.warning
        else:
            status = self.ok

        # Output
        self.shortoutput = "Found {0} files in {1}.".format(self.__result,
                                                            self.args.path)
        self.logger.debug("file_list: {}".format(self.__file_list))
        [self.longoutput.append(file_data.get('Name')) for file_data in self.__file_list]
        self.perfdata.append("{path}={result};{warn};{crit};0;".format(
            crit=self.args.critical,
            warn=self.args.warning,
            result=self.__result,
            path=self.args.path))

        # Return status and output to monitoring server.
        self.logger.debug("Return status and output.")
        status(self.output())


class FileAge(Wmi):

    """Get the file age, compare with the current date and time."""

    def __init__(self):
        super(FileAge, self).__init__()
        self.logger.debug("Init FileAge")

    def define_sub_options(self):
        super(FileAge, self).define_sub_options()
        self.fa_parser = self.subparsers.add_parser('fileage',
                                                    help='Get file age.',
                                                    description='Options\
                                                    for fileage.')
        self.fa_parser.add_argument('-q', '--query',
                                    required=False,
                                    help='wql for wmi.',
                                    dest='query')
        self.fa_parser.add_argument('-d', '--drive',
                                    required=True,
                                    help='the windows driver, like C:',
                                    dest='drive')
        self.fa_parser.add_argument('-p', '--path',
                                    default="\\\\",
                                    required=False,
                                    help='the folder, default is %(default)s',
                                    dest='path')
        self.fa_parser.add_argument('-f', '--filename',
                                    default="%%",
                                    required=False,
                                    help='the filename, default is %(default)s',
                                    dest='filename')
        self.fa_parser.add_argument('-e', '--extension',
                                    default="%%",
                                    required=False,
                                    help='the file extension, default is %(default)s',
                                    dest='extension')
        self.fa_parser.add_argument('-R', '--recursion',
                                    action='store_true',
                                    help='Recursive count file under path.',
                                    dest='recursion')
        self.fa_parser.add_argument('-w', '--warning',
                                    default=30,
                                    type=int,
                                    required=False,
                                    help='Warning minute of file, default is %(default)s',
                                    dest='warning')
        self.fa_parser.add_argument('-c', '--critical',
                                    default=60,
                                    type=int,
                                    required=False,
                                    help='Critical minute of file, default is %(default)s',
                                    dest='critical')

    def __get_file(self, path):
        self.wql_file = "SELECT LastModified FROM CIM_DataFile WHERE Drive='{0}' \
            AND Path='{1}' AND FileName LIKE '{2}' AND Extension LIKE '{3}'".format(self.args.drive,
                                                                                    path,
                                                                                    self.args.filename,
                                                                                    self.args.extension)
        self.file_data = self.query(self.wql_file)
        [self.file_list.append(file_data) for file_data in self.file_data]
        self.logger.debug("file_data: {}".format(self.file_data))
        return self.file_list

    def __get_folder(self, path):
        self.wql_folder = "SELECT FileName FROM CIM_Directory WHERE Drive='{0}' AND Path='{1}'".format(self.args.drive,
                                                                                                       path)
        self.file_list = self.__get_file(path)
        self.folder_data = self.query(self.wql_folder)
        self.logger.debug("folder_data: {}".format(self.folder_data))
        if self.folder_data:
            for folder in self.folder_data:
                self.new_path = (folder['Name'].split(":")[1] + "\\").replace("\\", "\\\\")
                self.__get_folder(self.new_path)
        return self.file_list

    def __get_current_datetime(self):
        """Get current datetime for every file."""
        self.wql_time = "SELECT LocalDateTime FROM Win32_OperatingSystem"
        self.current_time = self.query(self.wql_time)
        # [{'LocalDateTime': '20160824161431.977000+480'}]'
        self.current_time_string = str(self.current_time[0].get('LocalDateTime').split('.')[0])
        # '20160824161431'
        self.current_time_format = datetime.datetime.strptime(self.current_time_string, '%Y%m%d%H%M%S')
        # param: datetime.datetime(2016, 8, 24, 16, 14, 31) -> type: datetime.datetime
        return self.current_time_format

    def fileage_handle(self):
        """Get the number of file in the folder."""
        self.file_list = []
        self.ok_file = []
        self.warn_file = []
        self.crit_file = []
        status = self.ok

        if self.args.recursion:
            self.__file_list = self.__get_folder(self.args.path)
        else:
            self.__file_list = self.__get_file(self.args.path)
        self.logger.debug("file_list: {}".format(self.__file_list))
        # [{'LastModified': '20160824142017.737101+480', 'Name': 'd:\\test\\1.txt'},
        # {'LastModified': '20160824142021.392101+480', 'Name': 'd:\\test\\2.txt'},
        # {'LastModified': '20160824142106.460101+480', 'Name': 'd:\\test\\test1\\21.txt'}]

        for file_dict in self.__file_list:
            self.filename = file_dict.get('Name')
            if self.filename and self.filename != 'Name':
                self.logger.debug("===== start to compare {} =====".format(self.filename))

                self.file_datetime_string = file_dict.get('LastModified').split('.')[0]
                self.file_datetime = datetime.datetime.strptime(self.file_datetime_string, '%Y%m%d%H%M%S')
                self.logger.debug("file_datetime: {}".format(self.file_datetime))

                self.current_datetime = self.__get_current_datetime()
                self.logger.debug("current_datetime: {}".format(self.current_datetime))

                self.__delta_datetime = self.current_datetime - self.file_datetime
                self.logger.debug("delta_datetime: {}".format(self.__delta_datetime))
                self.logger.debug("warn_datetime: {}".format(datetime.timedelta(minutes=self.args.warning)))
                self.logger.debug("crit_datetime: {}".format(datetime.timedelta(minutes=self.args.critical)))
                if self.__delta_datetime > datetime.timedelta(minutes=self.args.critical):
                    self.crit_file.append(self.filename)
                elif self.__delta_datetime > datetime.timedelta(minutes=self.args.warning):
                    self.warn_file.append(self.filename)
                else:
                    self.ok_file.append(self.filename)

        # Compare the vlaue.
        if self.crit_file:
            status = self.critical
        elif self.warn_file:
            status = self.warning
        else:
            status = self.ok

        # Output
        self.shortoutput = "Found {0} files out of date.".format(len(self.crit_file))
        if self.crit_file:
            self.longoutput.append("===== Critical File out of date ====")
        [self.longoutput.append(filename) for filename in self.crit_file if self.crit_file]
        if self.warn_file:
            self.longoutput.append("===== Warning File out of date ====")
        [self.longoutput.append(filename) for filename in self.warn_file if self.warn_file]
        if self.ok_file:
            self.longoutput.append("===== OK File out of date ====")
        [self.longoutput.append(filename) for filename in self.ok_file if self.ok_file]
        self.perfdata.append("{path}={result};{warn};{crit};0;".format(
            crit=self.args.critical,
            warn=self.args.warning,
            result=len(self.crit_file),
            path=self.args.drive + self.args.path))

        # Return status and output to monitoring server.
        self.logger.debug("Return status and output.")
        status(self.output())


class SqlserverLocks(Wmi):

    """Check the attribute related to MSSQLSERVER_SQLServerLocks wmi class."""

    def __init__(self):
        super(SqlserverLocks, self).__init__()
        self.logger.debug("Init SqlserverLocks")

    def define_sub_options(self):
        super(SqlserverLocks, self).define_sub_options()
        self.sl_parser = self.subparsers.add_parser('sqlserverlocks',
                                                    help='Options for SqlserverLocks',
                                                    description='All options for SqlserverLocks')
        self.sl_parser.add_argument('-q', '--query',
                                    required=False,
                                    help='wql for wmi.',
                                    dest='query')
        self.sl_parser.add_argument('-m', '--mode',
                                    required=True,
                                    help='From ["LockTimeoutsPersec", "LockWaitsPersec", "NumberofDeadlocksPersec"]',
                                    dest='mode')
        self.sl_parser.add_argument('-w', '--warning',
                                    default=0,
                                    type=int,
                                    required=False,
                                    help='Default is %(default)s',
                                    dest='warning')
        self.sl_parser.add_argument('-c', '--critical',
                                    default=0,
                                    type=int,
                                    required=False,
                                    help='Default is %(default)s',
                                    dest='critical')

    def sqlserverlocks_handle(self):
        self.ok_list = []
        self.warn_list = []
        self.crit_list = []
        status = self.ok

        if self.args.mode == "LockTimeoutsPersec":
            self.wql = "select LockTimeoutsPersec from Win32_PerfFormattedData_MSSQLSERVER_SQLServerLocks"
        elif self.args.mode == "LockWaitsPersec":
            self.wql = "select LockWaitsPersec from Win32_PerfFormattedData_MSSQLSERVER_SQLServerLocks"
        elif self.args.mode == "NumberofDeadlocksPersec":
            self.wql = "select NumberofDeadlocksPersec from Win32_PerfFormattedData_MSSQLSERVER_SQLServerLocks"
        else:
            self.unknown("Unknown SqlServerLocks options")

        self.__results = self.query(self.wql)
        self.logger.debug("results: {}".format(self.__results))
        # [{'LockTimeoutsPersec': '0', 'Name': 'File'}, {'LockTimeoutsPersec': '0', 'Name': 'Database'}]
        # [[{'Name': 'OibTrackTbl', 'NumberofDeadlocksPersec': '0'}, {'Name': 'AllocUnit', 'NumberofDeadlocksPersec': '0'}]
        for lock_dict in self.__results:
            self.name = lock_dict.get('Name')
            self.logger.debug("name: {}".format(self.name))
            self.value = int(lock_dict.get(self.args.mode))
            self.logger.debug("value: {}".format(self.value))
            if self.value > self.args.critical:
                self.crit_list.append(self.name + " : " + self.value)
            elif self.value > self.args.warning:
                self.warn_list.append(self.name + " : " + self.value)
            else:
                self.ok_list.append(self.name + " : " + str(self.value))

        if self.crit_list:
            status = self.critical
        elif self.warn_list:
            status = self.warning
        else:
            status = self.ok

        self.shortoutput = "Found {0} {1} critical.".format(len(self.crit_list), self.args.mode)
        if self.crit_list:
            self.longoutput.append("===== Critical ====")
        [self.longoutput.append(filename) for filename in self.crit_list if self.crit_list]
        if self.warn_list:
            self.longoutput.append("===== Warning ====")
        [self.longoutput.append(filename) for filename in self.warn_list if self.warn_list]
        if self.ok_list:
            self.longoutput.append("===== OK ====")
        [self.longoutput.append(filename) for filename in self.ok_list if self.ok_list]
        self.perfdata.append("{mode}={result};{warn};{crit};0;".format(
            crit=self.args.critical,
            warn=self.args.warning,
            result=len(self.crit_list),
            mode=self.args.mode))

        # Return status and output to monitoring server.
        self.logger.debug("Return status and output.")
        status(self.output())


class Register(FileNumber, FileAge, SqlserverLocks):

    """Register your own class here."""

    def __init__(self):
        super(Register, self).__init__()


def main():
    """Register your own mode and handle method here."""
    plugin = Register()
    arguments = sys.argv[1:]
    if 'filenumber' in arguments:
        plugin.filenumber_handle()
    elif 'fileage' in arguments:
        plugin.fileage_handle()
    elif 'sqlserverlocks' in arguments:
        plugin.sqlserverlocks_handle()
    else:
        plugin.unknown("Unknown actions.")

if __name__ == "__main__":
    main()
