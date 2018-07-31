#!/usr/bin/env python
# -*- coding: utf-8 -*-
'''
#
# Objective of this small program is to report memory usage using
# useful memory metrics for Linux, by default for user postgres.
#
# It will group processes according to their URES (unique resident set size)
# and also do reports based on per-username, per-program name and per-cpu
# statistics.
#
# Inspired by work of Aleksandr Koltsoff (czr@iki.fi) meminfo.py 2006 released
# under GPL Version 2.
# https://github.com/majava3000/meminfo
# URES explanation: http://koltsoff.com/pub/ures/
#
# Current verison is not compatible with Python 3
# Modified by Bricklen Anderson, 2017
#

'''
import os
import sys
import pwd
import time
import argparse
import csv

# set this to 1 for debugging
DEBUG = 0
# we need to get the pagesize at this point
PAGE_SIZE = os.sysconf("SC_PAGESIZE")
# a map from /proc/PID/status memory-related fields into column headers
# other fields that start with Vm will user lower-case columns
VM_STATUS_MAP = {
    'Peak': 'VIRT-P',
    'Lck': 'LCKD',
    'HWM': 'HWRES',
    'Data': 'DATA',
    'Stk': 'STACK',
    'Exe': 'EXE',
    'Lib': 'LIB',
    'PTE': 'PTE'}


class UsernameCache:
    '''
    Utility class to act as a cache for UID lookups
    Since UID lookups will cause possible NSS activity
    over the network, it's better to cache all lookups.
    '''
    def __init__(self):
        self.uid_map = {}
        self.gid_map = {}

    def get_uid(self, uid):
        if uid in self.uid_map:
            return self.uid_map[uid]

        name_data = None
        try:
            name_data = pwd.getpwuid(uid)
        except Exception:
            pass
        if name_data is not None:
            name = name_data.pw_name
        else:
            # default the name to numeric representation in case it's not found
            name = "%s" % uid
        self.uid_map[uid] = name
        return name


# use a global variable to hold the cache so that we don't
# need a separate context-object/dict
NAME_CACHE = UsernameCache()


# utility class to aid in formatting
# will calculate the necessary amount of left-justification for each
# column based on the width of entries
# last entry will be unjustified
class JustifiedTable:
    def __init__(self):
        # this will keep the row data in string format
        self.rows = []
        # this will keep the maximum width of each column so far
        self.column_widths = []

    def add_row(self, row):
        # start by converting all entries into strings
        # (we keep data in string format internally)
        row = map(str, row)
        # check if we have enough column_widths for this row
        if len(self.column_widths) < len(row):
            self.column_widths += [0] * (len(row) - len(self.column_widths))
        # update column_widths if necessary
        for idx in range(len(row)):
            if self.column_widths[idx] < len(row[idx]):
                self.column_widths[idx] = len(row[idx])
        # add the row into data
        self.rows.append(row)

    def output_row(self, idx):
        row = self.rows[idx]
        for idx in range(len(row) - 1):
            if row[idx] is not "None":
                print "%*s" % (self.column_widths[idx], row[idx]),
        print row[-1]

    # we need to add optional header output every X lines
    # it is done with an empty line and repeating first row
    def output(self, max_lines=None):
        # always start with the header
        self.output_row(0)
        for idx in range(1, len(self.rows)):
            self.output_row(idx)
            if max_lines is not None:
                if idx % max_lines == 0:
                    print
                    self.output_row(0)


# parse parameters
def cli():
    parser = argparse.ArgumentParser(description='pg_meminfo')
    parser.add_argument('-u', '--user', type=str,
                        help='Retrieve mem info for processes owned by a'
                        ' specific user. Omit to calculate for all user procs.')
    parser.add_argument('-c', '--csv', action="store_true", default=None,
                        dest='csv_output',
                        help='Convert the output to CSV. Default is to STDOUT, '
                        'otherwise supply a file that the script can write to.')
    parser.add_argument('-o', '--output', type=str, dest='output_file',
                        default='stdout', help='Output results to this file. '
                        'Default is to STDOUT.')
    parser.add_argument('-s', '--sum-only', action="store_true", default=False,
                        dest='sum_only',
                        help='Emit the sum of the unique resident memory only. '
                        'If "-u" is supplied, sum will be only for that user.')
    parser.add_argument('-p', '--postgres-query', action="store_true",
                        default=False, dest='postgres_query',
                        help='Retrieve the query currently executing for each '
                        'process. Be aware there is overhead from querying '
                        'the database for every pid, which adds time and '
                        'resource overhead to the execution of this script. '
                        'Getting the query per pid is more accurate than passing '
                        'in a list of pids and returning the queries because '
                        'transient queries might have completed by the time the '
                        'call to pg_stat_activity is done, so queries that '
                        'started after the pid was pulled from /proc but before '
                        'the call to pg_stat_activity will not be the ones that '
                        'are actually using the memory.')
    parser.add_argument('-n', '--lines', default=None, dest='lines_of_output',
                        help='Retrieve only n lines of output. Default is all.')

    return parser.parse_args()


# utility to read a file
def parse_file(filename):
    f = open(filename, "rb")
    line = f.readline()
    del f
    i = line.find(b'\x00')
    if i == -1:
        return line
    return line[:i]


# utility to read and parse a comma delimited file (meminfo)
def parse_split_file(filename):
    f = open(filename, "rb")
    lines = f.readlines()
    del f

    lines = map(lambda x: x.strip().split(), lines)
    return lines


# utility to parse a file which contains one line with delim entries
def parse_delim_file(filename):
    f = open(filename, "rb")
    line = f.readline()
    del f

    return line.split()


# utility to parse a file which contains one line with delim numbers
def parse_number_file(filename):
    f = open(filename, "rb")
    line = f.readline()
    del f

    return map(int, line.split())


# return a hash of 'COLUMN-NAME': value -entries for
# process specific memory info
def get_process_mem_from_status(pid):
    ret = {}
    lines = parse_split_file("/proc/%d/status" % pid)

    for line in lines:
        if line[0][:2] == 'Vm':
            vm_label = line[0][2:-1]
            if vm_label in VM_STATUS_MAP:
                v = int(line[1])
                if v > 4 * 1024 * 1024:
                    v = -1
                ret[VM_STATUS_MAP[vm_label]] = v
    if len(ret) == 0:
        return None
    return ret


def get_postgres_query(pid):
    '''This function will only return results if "track_activities" is enabled'''
    import psycopg2

    conn = None
    try:
        qry_version = "SELECT current_setting('server_version_num')"
        qry_pre_96 = "select state as qry_state, coalesce(waiting::text,'') as waiting_state, query from pg_catalog.pg_stat_activity WHERE pid = %s"
        qry_96_up = "select state as qry_state, (case when wait_event_type is not null then wait_event_type || ':' || coalesce(wait_event,'')  else '' end) as waiting_state, query from pg_catalog.pg_stat_activity where pid = %s"
        conn = psycopg2.connect("dbname='postgres' user='postgres'")
        conn.set_session(readonly=True)
        cur = conn.cursor()
        cur.execute(qry_version)
        ver = cur.fetchone()
        if int(ver[0]) >= 9200 and int(ver[0]) < 90600:
            qry = qry_pre_96
        elif int(ver[0]) >= 90600:
            qry = qry_96_up
        else:
            if conn:
                conn.close()
            return

        # get the stats from the db
        cur.execute(qry,(pid,))
        row = cur.fetchone()
        if row:
            qry_state = row[0]
            waiting_state = row[1]
            query = row[2]
            return qry_state, waiting_state, query

    except psycopg2.DatabaseError, e:
        print 'Error %s' % e
        sys.exit(1)

    finally:
        if conn:
            conn.close()


# utility to return info for given pid (int)
# will return None if process doesn't exist anymore
# otherwise a hash:
# "pid" -> int(pid)
# "uid" -> int(uid)
# "gid" -> int(gid)
# "vmsize" -> int(vmsize in kilobytes)
# "res" -> int(res in kilobytes)
# "shared" -> int(shared in kilobytes)
# "ures" -> int(unique res in kilobytes)
# "cmd" -> string(command)
# "minflt" -> int(number of minor faults)
# "majflt" -> int(number of major faults)
# "state" -> string(state-char)
# "threads" -> int(number of threads, including main thread)
# "utime" -> int(ticks (0.01 secs) spent in user)
# "stime" -> int(ticks spent in kernel)
# "cpu" -> int(last cpu which executed code for this process)
# "status_mem" -> hash of additional fields
def get_process_info(pid, kernel_boot_ticks=0, uid=None):
    global PAGE_SIZE

    page_conv = PAGE_SIZE / 1024
    ret = None

    try:
        pinfo = {}

        # get process owner and group owner using stat
        stats = os.stat("/proc/%d" % pid)

        if uid is not None:
            if uid != stats.st_uid:
                return None
        pinfo["uid"] = stats.st_uid
        pinfo["gid"] = stats.st_gid

        pmem = parse_number_file("/proc/%d/statm" % pid)
        # size: total (VMSIZE)
        # resident: rss (total RES)
        # share: shared pages (SHARED)
        # we don't need the other entries
        del pmem[3:]
        pmem = map(lambda x: x * page_conv, pmem)

        # we ignore processes which seem to have zero vmsize (kernel threads)
        if pmem[0] == 0:
            return None
        pinfo["vmsize"] = pmem[0]
        pinfo["res"] = pmem[1]
        pinfo["shared"] = pmem[2]
        pinfo["ures"] = pmem[1] - pmem[2]

        # get status (this changes between kernel releases)
        psmem = get_process_mem_from_status(pid)
        pinfo["status_mem"] = psmem

        pstat = parse_delim_file("/proc/%d/stat" % pid)
        pcmd = parse_file("/proc/%d/cmdline" % pid)
        # 1: filename of the executable in parentheses
        # 2: state
        # 9: minflt %lu: minor faults (completed without disk access)
        # 11: majflt %lu: major faults

        pinfo["cmd"] = pcmd
        pinfo["state"] = pstat[2]
        pinfo["minflt"] = int(pstat[9])
        pinfo["majflt"] = int(pstat[11])
        pinfo["utime"] = int(pstat[13])
        pinfo["stime"] = int(pstat[14])
        pinfo["cpu"] = int(pstat[38])
        pinfo["exists_for"] = kernel_boot_ticks - int(pstat[21])
        # 13 = usertime (jiff)
        # 14 = kernel time (jiff)
        # 21 = start time (jiff)
        # 38 = last CPU
        # hah. these aren't actually in jiffies, but in USER_HZ
        # which has been defined as 100 always

        pinfo["pid"] = pid
        pinfo["ppid"] = int(pstat[3])

        # attempt to count the number of threads
        # note than on older linuxen there is no /proc/X/task/
        thread_count = 0
        try:
            if os.access("/proc/%d/task/" % pid, os.X_OK):
                thread_count = len(os.listdir("/proc/%d/task" % pid))
        except Exception:
            pass
        pinfo["threads"] = thread_count

        try:
            # Get the Postgresql query details, if any
            qry_state, qry_waiting, query = get_postgres_query(pid)
            if query:
                pinfo['qry_state'] = qry_state
                pinfo['waiting_state'] = qry_waiting
                pinfo['query'] = query
        except:
            pass

        ret = pinfo

    except Exception:
        pass

    return ret


# utility to return process information (for all processes)
# this is basically where most of the work starts from
def get_process_infos():
    # this will be the return structure
    # the key will be the pid
    pinfos = {}
    args = cli()

    filter_process_by_uid = None
    if args.user:
        try:
            filter_process_by_uid = pwd.getpwnam(args.user).pw_uid
        except KeyError:
            print '[ERROR] User does not exist.'
            sys.exit(1)

    # start by getting kernel uptime
    kernel_uptime, kernel_idle_time = parse_delim_file("/proc/uptime")
    kernel_uptime = int(float(kernel_uptime) * 100)

    # we need to iterate over the names under /proc at first
    for n in os.listdir("/proc"):
        # we shortcut the process by attempting a PID conversion first
        # and statting only after that
        # (based on the fact that the only entries in /proc which are
        # integers are the process entries). so we don't do extra
        # open/read/closes on proc when not necessary
        try:
            pid = int(n)
        except Exception:
            continue

        # at this point we know that n is a number
        # note that it might be so that the process doesn't exist anymore
        # this is why we just ignore it if it has gone AWOL.
        pinfo = get_process_info(pid, kernel_uptime, filter_process_by_uid)
        if pinfo is not None:
            pinfos[pid] = pinfo

    return pinfos


# utility to return human readable time
# three return formats:
# < hour: x:%.2y
# rest: h:%.2y:%.2z
def get_time(ticks):
    secs_total = ticks / 100.0
    if secs_total < 60:
        return "%ds" % secs_total

    secs = secs_total % 60
    secs_total -= secs
    minutes = secs_total / 60
    if minutes < 60:
        return "%dm%.2ds" % (minutes, secs)
    hours = minutes / 60
    minutes = minutes % 60
    return "%dh%.2dm%.2ds" % (hours, minutes, secs)


# routine that will tell when something started based on given value in ticks
# ticks is understood to mean "for" (when something was started X ticks ago)
# the label is "started", so an absolute timestamp would be nice
# if difference to current clock is more than one day, we display the date
def get_elapsed(ticks, now=time.time()):
    ticks /= 100  # conv to seconds
    if ticks < 60 * 60 * 24:
        return time.strftime("%H:%M:%S", time.localtime(now - ticks))

    return time.strftime("%Y-%m-%d", time.localtime(now - ticks))


# utility to get process info as a row suitable into tabling
# note that this might get a bit hairy wrt the extra memory fields
# we need to preserve order and insert "" if there are missing
# fields for this process.
#
# stat_map:
# ordered list of field-names that we want to output
def get_process_row(pinfo, stat_map, with_cpu=0, args=None, get_current_time=False):
    # PID UID URES SHR VIRT MINFLT MAJFLT S CMD"
    username = NAME_CACHE.get_uid(pinfo["uid"])

    currentTime = []
    if get_current_time:
        currentTime = [time.time()]
    cpu = None
    if with_cpu:
        cpu = pinfo["cpu"]

    mainInfo = [
        pinfo["pid"],
        username,
        pinfo["ures"],
        pinfo["shared"],
        pinfo["vmsize"]]
    restInfo = [pinfo["minflt"],
                pinfo["majflt"],
                cpu,
                pinfo["threads"],
                get_elapsed(pinfo["exists_for"]),
                pinfo["state"],
                pinfo["cmd"]]

    queryInfo = []
    if args.postgres_query:
        queryInfo = [pinfo.get('qry_state',''), pinfo.get('waiting_state',''), pinfo.get('query','')]

    # generate the status_mem entries
    status_mem = pinfo["status_mem"]
    status_mem_entries = []
    for label in stat_map:
        if label in status_mem:
            status_mem_entries.append(status_mem[label])
        else:
            status_mem_entries.append("")

    return currentTime + mainInfo + status_mem_entries + restInfo + queryInfo


# utility to print a label:
# - print empty line
# - print text
# - print underscore for the line
def print_label(s):
    print
    print s
    print '-' * len(s)


# main routine that gathers and outputs the reports
def run_it():
    args = cli()
    if args.output_file != 'stdout':
        if args.csv_output is None:
            print '[WARNING] Cannot emit process table to file unless it is in CSV format.'
            return

    # stat_map is created as follows:
    # - we iterate over all process data and their status_mem-hash
    #   we insert the keys into statusMap-hash
    #   convert the statusMap into a list
    #   sort it
    stat_map = {}
    pinfos = get_process_infos()

    # we now need to organize the list of entries according to their ures
    # for this we'll create a list with two entries:
    # [ures, pid]
    # (since pid can be used to access the process from the pinfos-hash)
    plist = []
    max_cpu = 0
    ures_sum = 0
    for pid, v in pinfos.items():
        max_cpu = max(max_cpu, v["cpu"])
        plist.append((v["ures"], pid))
        status_mem = v["status_mem"]
        ures_sum += int(v["ures"])
        # add the keys from this process status_mem
        if status_mem:
            for k in status_mem.keys():
                stat_map[k] = None

    # If user only wants the sum, print that and exit
    if args.sum_only:
        msg = 'Unique Resident Memory sum: ' + str(ures_sum) + ' Kilobytes'
        if args.user:
            msg += ', for user ' + str(args.user)
        print msg
        return

    # use two steps in order to work on older pythons (newer ones
    # can use reverse=True keyparam)
    plist.sort()
    plist.reverse()

    # prepare the stat_map
    stat_map = stat_map.keys()
    stat_map.sort()
    time_header = ["epoch_time"]
    cpu_header = "CPU"
    main_header = ["PID", "UID", "URES", "SHR", "VIRT"]
    post_header = ["MINFLT", "MAJFLT", cpu_header, "threads", "started", "S", "CMD"]
    stat_header = map(lambda x: x.lower(), stat_map)
    query_header = []

    result_rows_limit = None
    if args.lines_of_output and args.lines_of_output > 0:
        result_rows_limit = args.lines_of_output

    get_current_time=False
    if args.postgres_query:
        i=0
        j=0
        for dummy, pid in plist:
            # Only iterate result_rows_limit, if args.lines_of_output was supplied.
            if not result_rows_limit or (result_rows_limit and j < int(result_rows_limit)):
                row = get_process_row(pinfos[pid], stat_map, max_cpu > 0, args, get_current_time=get_current_time)
                if len(row[-1]) > 0:
                    i += 1
                if i > 0:
                    query_header = ['qry_state','qry_waiting','query']
            j += 1

    if args.csv_output is None:
        process_table = JustifiedTable()
        process_table.add_row(main_header + stat_header + post_header + query_header)

    # Clear the file if one was supplied
    try:
        if args.output_file != 'stdout':
            with open(args.output_file, 'w') as fout:
                fout.truncate()
    except IOError as err:
        print 'Attempted to write to ' + args.output_file + '. Error: ' + err.strerror
        sys.exit(1)

    i = 0
    j=0
    if args.csv_output is not None:
        get_current_time=True
    for dummy, pid in plist:
        if not result_rows_limit or (result_rows_limit and j < int(result_rows_limit)):
            row = get_process_row(pinfos[pid], stat_map, max_cpu > 0, args, get_current_time=get_current_time)
            if args.csv_output is not None:
                # Write to file if one was defined.
                if args.output_file != 'stdout':
                    with open(args.output_file, 'ab') as csvfile:
                        csvwriter = csv.writer(csvfile)
                        if i == 0:
                            csvwriter.writerow(time_header + main_header + stat_header + post_header + query_header)

                        csvwriter.writerow(map(str, row))
                else:
                    csvstdout = csv.writer(sys.stdout)
                    if i == 0:
                        csvstdout.writerow(time_header + main_header + stat_header + post_header + query_header)
                    csvstdout.writerow(map(str, row))
            else:
                process_table.add_row(row)
            i += 1
            j += 1

    # Write to stdout or to file
    if args.output_file == 'stdout':
        if args.csv_output is None:
            process_table.output(None)
            msg = 'Unique Resident Memory sum: ' + str(ures_sum) + ' Kilobytes'
            if args.user:
                msg += ', for user ' + str(args.user)
            print msg


if __name__ == '__main__':
    # If piping to head/tail, add "2>/dev/null"
    # eg. python pg_meminfo.py 2>/dev/null | head -5
    run_it()


'''Tests
# Fail because of permission denied if run by non-root user
python /tmp/pg_meminfo.py -c --output /root/foo.csv

# Return only the sum of the URES
python /tmp/pg_meminfo.py -s

# Return the Unique Resident Memory for all users
python /tmp/pg_meminfo.py

# Return the Unique Resident Memory for a specific user
python /tmp/pg_meminfo.py -u postgres

# Return only the sum of the URES, all other flags should be ignored except "user"
python /tmp/pg_meminfo.py -c -o /root/foo.csv --sum-only -u postgres

# output csv to stdout
python /tmp/pg_meminfo.py -c

# Output csv to file and include the queries (if any)
python /tmp/pg_meminfo.py -c -o /tmp/foo.csv --postgres-query

# Should fail because output file can only be used with csv
python /tmp/pg_meminfo.py --output /tmp/foo_a.csv

# Output 10 rows of csv (including header) without error
python /tmp/pg_meminfo.py -c --postgres-query -u postgres -n 10

'''
