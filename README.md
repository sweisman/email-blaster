# email-blaster
High performance SMTP client to send email written in Perl and using Linux epoll mechanism.

Written in 2006 or 2007 before the Global Financial Crisis to send emails to a very large list of opt-in contacts.

What's unusual about it are several things:

1. It uses the Linux kernel `epoll` mechanism to handle events instead of the more common `select` (which Perl supports directly), by invoking the kernel `epoll` APIs directly vis syscalls.
`Epoll` was still new at the time, and state of the art.
2. The company had six Class C (ie `/24`) blocks of IP addresses, and the code cycles through the addresses while running. It's a good demonstration of dynamic adjustment of network settings.
3. It is 100% Perl with few dependencies.
4. It is extremely fast. On a modest Pentium 4 with 1GB RAM and a modest network connection, it could easily send 200K emails per hour.

The code is sanitized but otherwise unmodified, since that would destroy the context of using the various mechanisms.

On startup, it spawns child processes (70 was the default, tuned to the hardware it ran on) to send emails.
The parent process calculates the emails to send, collates them by recipient domain, then dispatches them to each child to send.
The child receives the instructions, opens an SMTP connection to the recipient domain, and sends the email. It then sends a response back to the parent.
