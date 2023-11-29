# email-blaster
High performance SMTP client to send email written in Perl and using Linux epoll mechanism.

Written in 2006 or 2007 before the Global Financial Crisis to send emails to a very large list of opt-in contacts.

What's unusual about it are several things:

1. It uses the Linux kernel `epoll` mechanism to handle events instead of the more common `select` (which Perl supports directly), by invoking the kernel `epoll` APIs directly vis syscalls.
`Epoll` was new at the time, and state of the art, but also more complicated to set up and use.
2. The company had six Class C (ie `/24`) blocks of IP addresses (roughly 1500, worth a small fortune today), and the code cycles through the addresses used to open the connection to the SMTP server while running. It's a good demonstration of dynamic adjustment of network settings.
3. It is 100% Perl with few dependencies.
4. It is extremely efficient and fast. On a modest single core Pentium 4 with 1GB RAM and a T1-level connection, it could send around 200K emails per hour.

The code is sanitized but otherwise unmodified, since that would destroy the context of using the various mechanisms.

On startup, it spawns child processes (70 was the default, tuned to the hardware it ran on) to send emails.
The parent process calculates the emails to send, collates them by recipient domain, then dispatches them to each child to send.
The child receives the instructions, opens an SMTP connection to the recipient domain, and sends the email. It then sends a response back to the parent, which logs the exchange.

There were plans to convert the hard-coded version you see into a general solution with a web-based front end.
