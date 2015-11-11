
from time import time, sleep
from uuid import UUID
from binascii import b2a_hex
import argparse
import getpass
import sys

from fluxclient.upnp.task import UpnpTask


def main():
    parser = argparse.ArgumentParser(description='flux printer config tool')
    parser.add_argument(dest='uuid', type=str, help='Device UUID')

    options = parser.parse_args()

    uuid = UUID(hex=options.uuid)
    task = UpnpTask(uuid)

    sys.stdout.write("""UUID: %s
Serial: %s
Model: %s
Version: %s
Has Password: %s
Remote Addr: %s
""" % (task.uuid, task.serial, task.model_id,
       task.remote_version,
       task.has_password and "YES" or "NO",
       task.remote_addr))
    sys.stdout.flush()

    if task.has_password:
        return auth_passwd(task)
    else:
        return auth_nopasswd(task)


def auth_passwd(task):
    passwd = getpass.getpass()
    print(task.auth_with_password(passwd))


def auth_nopasswd(task, timegap=1.0):
    last_status = None
    while True:
        stemp = time()

        resp = task.auth_without_password()
        if resp:
            status = resp.get("status")
            if status == "padding" and not last_status:
                sys.stdout.write(
                    "Press FLUX 3D Printer button UNTIL auth successed...\n")
                sys.stdout.flush()
                last_status = status

            elif status == last_status == "padding":
                sys.stdout.write(".")
                sys.stdout.flush()

            elif status == "blocking":
                sys.stdout.write("\n\nAuth failed\n")
                sys.stdout.flush()
                return False

            elif status == "ok":
                access_id = b2a_hex(task.access_id).decode()
                sys.stdout.write("\n\nAccess ID: %s\n" % access_id)
                sys.stdout.write("Auth successed\n")
                sys.stdout.flush()
                return True

            else:
                sys.stdout.write(
                    "\n\nPrinter return unknow status: %s\n" % status)
                sys.stdout.flush()
                return True
        else:
            sys.stdout.write("?")
            sys.stdout.flush()

        sleep(max(timegap - time() + stemp, 0))


if __name__ == "__main__":
    sys.exit(main())