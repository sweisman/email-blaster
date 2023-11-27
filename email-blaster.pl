#!/usr/bin/perl
use strict;

use lib '/opt/cmf/lib';

use Fcntl ();
use Socket ();
use Net::DNS ();
use Net::SMTP ();
use Getopt::Std ();

use cmf ();
use cmf::db ();

#Net::SMTP->debug(1) if $cmf::DEBUG;

# args: -n num -f filter -t template -d days
# -n max number of emails to send out this run
# -f comma separated list of states to include (eg CA,NY) - no spaces!
# -d only send emails to leads that haven't received an email from us within the past x days
# -p number of processes to use to send emails
# -c number of emails to send before cycling to next ip address

my ($lock, %opt, $filter);

open($lock, $0);
die "$0 failed to get a lock: '$!'" unless flock($lock, Fcntl::LOCK_EX() | Fcntl::LOCK_NB());

Getopt::Std::getopts('n:f:d:p:c:', \%opt);

my @dsn = ('dbi:mysql:mortgage:localhost', 'user', 'password');
cmf::db::begin(@dsn) or die "no mysql available\n";
cmf::db::end();

$opt{n} ||= 100000;
$opt{d} ||= 30;
$opt{p} ||= 70;
$opt{c} ||= 1000;
$opt{f} =~ tr/[A-Z]/[a-z]/;
$opt{f} =~ s/[^A-Z]+//g;
$opt{f} =~ s/(.{2})/$1,/g;
$opt{f} =~ s/,$//;
$opt{f} = " state in ('$opt{f}') and " if $opt{f};

my $EPOLLIN       = 1;
my $EPOLL_CTL_ADD = 1;
my $EPOLL_CTL_DEL = 2;

my @dow = qw(Sun Mon Tue Wed Thu Fri Sat);
my @month = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %state =
(
    AL => 'Alabama',
    AK => 'Alaska',
    AB => 'Alberta',
    AZ => 'Arizona',
    AR => 'Arkansas',
    BC => 'British Columbia',
    CA => 'California',
    CO => 'Colorado',
    CT => 'Connecticut',
    DE => 'Delaware',
    FL => 'Florida',
    GA => 'Georgia',
    HI => 'Hawaii',
    ID => 'Idaho',
    IL => 'Illinois',
    IN => 'Indiana',
    IA => 'Iowa',
    KS => 'Kansas',
    KY => 'Kentucky',
    LA => 'Louisiana',
    ME => 'Maine',
    MB => 'Manitoba',
    MD => 'Maryland',
    MA => 'Massachusetts',
    MI => 'Michigan',
    MN => 'Minnesota',
    MS => 'Mississippi',
    MO => 'Missouri',
    MT => 'Montana',
    NE => 'Nebraska',
    NV => 'Nevada',
    NB => 'New Brunswick',
    NH => 'New Hampshire',
    NJ => 'New Jersey',
    NM => 'New Mexico',
    NY => 'New York',
    NF => 'Newfoundland',
    NC => 'North Carolina',
    ND => 'North Dakota',
    NS => 'Nova Scotia',
    OH => 'Ohio',
    OK => 'Oklahoma',
    ON => 'Ontario',
    OR => 'Oregon',
    PA => 'Pennsylvania',
    PE => 'Prince Edward Island',
    PR => 'Puerto Rico',
    QC => 'Quebec',
    RI => 'Rhode Island',
    SK => 'Saskatchewan',
    SC => 'South Carolina',
    SD => 'South Dakota',
    TN => 'Tennessee',
    TX => 'Texas',
    UT => 'Utah',
    VT => 'Vermont',
    VA => 'Virginia',
    WA => 'Washington',
    DC => 'Washington, D.C.',
    WV => 'West Virginia',
    WI => 'Wisconsin',
    WY => 'Wyoming'
);
my ($sig_catch, $sig_hold, $dns, $child_count);
my $parent_pid = $$;

my $header = qq{Message-ID: <%message_id%>
Date: <%date%>
From: "<%from_name%>" <<%from_email%>>
Sender: <%from_email%>
Reply-To: <<%reply_to_email%>>
To: <%to_email%>
Subject: <%subject%>
MIME-Version: 1.0
Content-Type: text/plain; charset=ISO-8859-1
Content-Transfer-Encoding: 8bit
Content-Disposition: inline\n\n};

my $footer = "\n--\nThis email was generated by <<%domain%>>.

If you don't want to receive further emails from <<%domain%>>,
please either send an email to <unsubscribe+<%id%>@<%domain%>>
or click on the link below:

http://<%domain%>/cgi/unsubscribe/<%id%>

<%domain%>";

my @template =(
qq{<%greeting%>,

You requested information about a home loan in <%year%>. Since your inquiry there several new equity options available to you.

Your property has built additional equity and your mortgage has seasoned enough to allow you a cash out or a significant reduction in your monthly payment.

Allow us to take a moment of your time and send you 4 different options you have available that are at no cost to you.

Please visit us below and a you will receive your proposals in a matter of minutes.

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba001},
qq{<%greeting%>,

You visited our website in <%year%> regarding your home at <%address%> and we noticed that we did not receive all your information. You are pre-approved for savings.

Please follow the below link and we will submit you a proposal that could save you money within minutes.

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba002},
qq{<%greeting%>,

We have some very exciting news for the month of <%month%>. Your monthly payment can be substantially reduced with your <<%domain%>> refinance option.

Our service is Free to <%city_or_state%> homeowners and requires No Credit Checks. We have helped over 1.8 million homeowners with the home finance needs and you will get 4 qualified responses in minutes from qualified lenders in <%city_or_state%>.

So no matter what your current credit history is you can get a loan that will reduce your current monthly payments.

Fill out our 45 second fast quote and start saving in the month of May.

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba003},
qq{<%greeting%>,
<%address_full%>
The above property has been submitted to <<%domain%>> and we specialize in <%state_long%> homeowners that want to deal with a local lender.

Please provide us with some additional information so we can further process your request.

Your personal application link is below please complete and submit and we will be in contact with you by noon on Monday.

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba004

Thank you in advance for your business,

<%domain%>},
qq{<%greeting%>,

Your home at <%address%> is in demand and our lenders are ready to cash out your equity.

You have qualified for a streamlined equity cash out with no cost out of pocket.

Since <%year%> property values in and around <%city_or_zip%> have gone through the roof and rates have made this unique situation available to <%city_or_zip%> homeowners like you.

This means in the month of <%month%> you can cash out your equity or choose to lower your monthly payment.

For more information and 4 quotes in minutes from <%city_or_state%> lenders in your area please follow the below link.

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba005},
qq{<%greeting%>,

During the past 12 months we have seen growth and property values shoot through the roof in <%city_or_state%>. <<%domain%>> is notifying all homeowners located in <%city_or_zip_or_state%> of significant payment deductions.

The fact that your home is located at <%address%> and is located in a <%city_or_zip_or_state%> finance zone enables you to a monthly payment reduction.

Please follow the below link and to see the savings pulled within minutes

http://<%domain%>/refinance.html?lid=<%id%>&cid=ba006});

foreach (@template)
{
    s/\r//g;
    $_ = text_wrap("$header$_$footer");
}

#$SIG{__WARN__} = sub { msg(@_) };
#$SIG{__DIE__} = sub { die msg(@_) };

sub reaper
{
    $child_count-- while waitpid(-1, 1) > 0;
    $SIG{CHLD} = \&reaper;
}

$SIG{CHLD} = \&reaper;

$SIG{KILL} = $SIG{TRAP} = $SIG{ABRT} = $SIG{STOP} = $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = $SIG{HUP} =
    sub
    {
        $sig_catch = shift;
        $SIG{$sig_catch} = 'IGNORE';
        kill($sig_catch, -$parent_pid); # send to all procceses in group
        #return msg('[' . localtime() . "] [${$}] killed by $sig_catch") if $parent_pid == $$;
        exit unless $sig_hold;
    };

parent_main();

exit;

sub parent_main
{
    my ($pid, $fileno, %pipe, $pipe, $parent_pipe, $child_pipe, %row, $blast_count, %master, @master, %domain, $from_domain, $cycle_count, $list, $process, $domain, $line);

    my $epoll = epoll_create();
    die "no epoll\n" if $epoll < 0;

    setpgrp;

    while ($child_count < $opt{p})
    {
        ($child_pipe, $parent_pipe) = pipe_pair();

        $pid = fork;
        die "fork: $!" unless defined($pid);
        return child_main($parent_pipe) unless $pid;
        close $parent_pipe;
        $fileno = fileno($child_pipe);
        $pipe{$fileno} = $child_pipe;
        epoll_ctl($epoll, $EPOLL_CTL_ADD, $fileno, 1);
        $child_count++;
    }

    cycle_data();

    cmf::db::begin(@dsn) or return;
    my $fetch = cmf::db::select("select id, email
                                 from lead
                                 where $opt{f}
                                       (contact_date is null or DATEDIFF(CURRENT_DATE, contact_date) > $opt{d}) and
                                       email_status is null limit $opt{n}", \%row);
    if (!$fetch)
    {
        out('query error');
        return;
    }

    while (&$fetch())
    {
        push @{$master{(split(/\@/, $row{email}))[1]}}, $row{id};
    }
    cmf::db::end();

    if (keys(%master) == 0)
    {
        foreach (keys(%pipe))
        {
            $pipe = $pipe{$_};
            epoll_ctl($epoll, $EPOLL_CTL_DEL, $_, 0);
            close($pipe);
        }

        $SIG{USR2} = 'IGNORE';
        kill(USR2 => -$$);

        out('no leads');
        exit;
    }

    out(scalar(keys(%master)), ' domains');

    foreach (keys(%master))
    {
        push @master, $master{$_};
        $domain{"$master{$_}"} = $_; # use ref address as index
    }

    %master = ();

    # set minimum number of emails to send per connection (either 25 or 0.1% of $opt{n}, whichever is bigger)
    my $min = int($opt{n} / 1000);
    $min = ($min > 25 ? $min : 25);
    $min = 15;

    my $start = time;
    my $event;

    $SIG{USR1} = 'IGNORE';
    kill(USR1 => -$$);

    do
    {
        $from_domain = domain(cycle_ip()) unless $cycle_count;

        $list = shift(@master);
        $domain = $domain{"$list"};

        if (@$list > $min)
        {
            $process = [splice(@$list, 0, $min)];
            push @master, $list if @$list > 0;
        }
        elsif (@$list > 0)
        {
            $process = $list;
        }
        else
        {
            next;
        }

        $event = epoll_wait($epoll, -1);
        $pipe = $pipe{$$event[0]};
        chomp($line = <$pipe>);
        print $pipe "$from_domain\t$domain\t", join("\t", @$process), "\n";

        $cycle_count += @$process;
        $cycle_count = 0 if $cycle_count >= $opt{c} || @master < $opt{p};
# xxx put in check to pare children if @process < $child_count
# xxx have it cycle once through each run of the queue
    } while @master > 0;

    out('sending termination signal');

    foreach (keys(%pipe))
    {
        $pipe = $pipe{$_};
        print $pipe "bye\n";
        epoll_ctl($epoll, $EPOLL_CTL_DEL, $_, 0);
        close($pipe);
    }

    sleep(1);

    cycle_restore();

    my $sleep;

    out('waiting for children to terminate');
    while ($child_count)
    {
        sleep(1);
        if (++$sleep > 30)
        {
            $SIG{USR2} = 'IGNORE';
            kill(USR2 => -$$);
            last;
        }
    }
    out('children terminated');

    my ($status, $id, @update);
    %row = ();

    opendir(my $dir, $cmf::TMP);
    while (my $file = readdir($dir))
    {
        next unless $file =~ /^blast-\d+\.log$/;

        open(my $data, '<', "$cmf::TMP/$file");
        while ($line = <$data>)
        {
            chomp($line);
            ($status, $id) = split(/\s+/, $line);
            push @{$row{$status}}, $id;
        }
        close($data);
    }
    closedir($dir);

    cmf::db::begin(@dsn) or return;
    foreach my $status (sort(keys(%row)))
    {
        out("status $status: ", scalar(@{$row{$status}}));
        $blast_count += scalar(@{$row{$status}});

        while (@{$row{$status}} > 0)
        {
            out("status $status: ", scalar(@{$row{$status}}), ' records remaining');
            @update = splice(@{$row{$status}}, 0, 2000);
            next unless @update > 0;
            $status > 0 ?
                cmf::db::do(qq{update lead set email_status = $status where email_status is null and id in ('} . join(q{','}, @update) . q{')})
                :
                cmf::db::do(q{update lead set contact_date = CURRENT_DATE where id in ('} . join(q{','}, @update) . q{')});
        }
    }
    cmf::db::end();

    `rm -f $cmf::TMP/blast-*.log`;

    out("$blast_count leads processed in ", time - $start, ' seconds');
}

sub child_main
{
    my $parent_pipe = shift;
    my ($rout, $rin, $line, $log, $from_domain, $domain, @list, %row, $response, @update);

    vec($rin, fileno($parent_pipe), 1) = 1;

    $SIG{USR1} = sub { $SIG{USR1} = 'IGNORE' };
    $SIG{USR2} = sub { print $log join("\n", @update), "\n" if $log; close($log); exit };

    sleep; # wait for parent to be ready

    open($log, '>>', "$cmf::TMP/blast-$$.log");

    cmf::db::begin(@dsn) or return;

    while (1)
    {
        print $parent_pipe "wait $$\n";
        select($rout = $rin, undef, undef, undef);
        chomp($line = <$parent_pipe>);

        ($from_domain, $domain, @list) = split(/\s+/, $line);

        last if $from_domain eq 'bye';
        next unless $domain && @list > 0;

        my @date = gmtime();
        $date[5] += 1900;
        my $date = sprintf("$dow[$date[6]], %02d $month[$date[4]] $date[5] %02d:%02d:%02d -0000", @date[3, 2, 1, 0]);

        my $smtp = smtp_connect($from_domain, $domain);
        if (!$smtp)
        {
            out("domain $domain not reachable");
            print $log "11\t$_\n" for @list; # xxx
            next;
        }

        @update = ();

        my $fetch = cmf::db::select("select id, first_name, last_name, address, city, state, zip, email from lead where id in ('" . join(q{','}, @list) . '\')', \%row) or return;

        while (&$fetch())
        {
            $row{date} = $date;
            $row{domain} = $from_domain;

            $sig_hold = 1;

            $response = smtp_send($smtp, \%row);

            if ($response < 0)
            {
                # this email was blocked, assume all remaining are blocked too
                $smtp->quit() if $response == -2;
                $smtp = undef;
                push @update, "10\t$row{id}";
                push @update, "10\t$row{id}" while &$fetch();
                last;
            }
            elsif ($response == 3)
            {
                push @update, "9\t$row{id}"; # indeterminate status
            }
            elsif ($response == 2)
            {
                push @update, "1\t$row{id}"; # bounce
            }
            elsif ($response)
            {
                push @update, "0\t$row{id}"; # success
            }
            else
            {
                push @update, "9\t$row{id}"; # indeterminate status
            }

            $sig_hold = 0;

            $_ = undef for values(%row);
        }

        if ($smtp && $response >= 0)
        {
            $smtp->quit();
            $smtp = undef;
        }

        out(scalar(@list), " emails processed for $domain");

        print $log join("\n", @update), "\n";
    }

    close($log);

    cmf::db::end();
}

sub _smtp_connect
{
    my $ip = shift;
    my $from_domain = shift;
    my $debug = 0;
    my $smtp;

    eval
    {
        local $SIG{ALRM} = sub {die "ALRM\n"};
        alarm(10);
        $smtp = Net::SMTP->new($ip, Hello => $from_domain, Debug => $debug) if $ip;
        alarm(0);
    };

    return $smtp;
}

sub smtp_connect
{
    my $from_domain = shift;
    my $domain = shift;
    my ($smtp, $ip);

    $smtp = _smtp_connect($ip, $from_domain)
        if $ip = cmf::db::get("select ip from dns where domain = '$domain'");

    if ($smtp && $smtp->status() == 2)
    {
        return $smtp;
    }
    elsif ($smtp)
    {
        cmf::db::do("delete from dns where domain = '$domain'");
        $smtp = undef;
    }
    elsif ($ip)
    {
        cmf::db::do("delete from dns where domain = '$domain'");
    }

    if (!$smtp)
    {
        my @mx = Net::DNS::mx(($dns ||= Net::DNS::Resolver->new()), $domain);
        foreach (@mx)
        {
            if ($smtp = _smtp_connect($ip = $_->exchange(), $from_domain))
            {
                if ($smtp->status() == 2)
                {
                    cmf::db::do("insert into dns (domain, ip) values ('$domain', '$ip') on duplicate key update ip = '$ip'");
                    return $smtp;
                }
                else
                {
                    $smtp->quit();
                    $smtp = undef;
                }
            }
        }
    }

    if (!$smtp)
    {
        my $type;
        my $query = $dns->search($domain) or return;
        foreach ($query->answer())
        {
            $type = $_->type();
            $ip = ($type eq 'A' ? $_->address() : ($type eq 'CNAME' ? $_->cname() : ''));
            next unless $ip;

            if ($smtp = _smtp_connect($ip, $from_domain))
            {
                if ($smtp->status() == 2)
                {
                    cmf::db::do("insert into dns (domain, ip) values ('$domain', '$ip') on duplicate key update ip = '$ip'");
                    return $smtp;
                }
                else
                {
                    $smtp->quit();
                    $smtp = undef;
                }
            }
        }
    }

    return;
}

my (%MAIL, %RCPT);

sub smtp_send
{
    my $smtp = shift or return;
    my $param = shift or return;

    $$param{from_name} = from();
    $$param{from_email} = "$$param{from_name}\@$$param{domain}";
    $$param{reply_to_email} = "$$param{from_name}+$$param{id}\@$$param{domain}";
    $$param{message_id} = '<' . int(rand(1000000000000)) . "\@$$param{domain}>";

    if ($$param{first_name} && $$param{last_name})
    {
        my $name = "$$param{first_name} $$param{last_name}";
        $name =~ s/"/'/g;
        $$param{to_email} = qq{"$name" <$$param{email}>};
    }
    elsif ($$param{first_name})
    {
        my $name = $$param{first_name};
        $name =~ s/"/'/g;
        $$param{to_email} = qq{"$name" <$$param{email}>};
    }
    else
    {
        $$param{to_email} = "<$$param{email}>";
        $$param{greeting} = 'Hello';
    }

    $$param{greeting} ||= $$param{first_name};

    if ($$param{address})
    {
        $$param{address_full} = "\n$$param{address}";

        if ($$param{city} && $$param{state})
        {
            $$param{address_full} .= "\n\n$$param{city}, $$param{state}";
            $$param{address_full} .= " $$param{zip}" if $$param{zip};
        }

        $$param{address_full} .= "\n";
    }

    $$param{state_long} = $state{$$param{state}};
    $$param{city_or_state} = $$param{city} || $$param{state_long};
    $$param{city_or_zip} = $$param{city} || $$param{zip};
    $$param{city_or_zip_or_state} = $$param{city_or_zip} || $$param{state_long};

    subject($param);

    my $template = $template[template($param)];
    $template =~ s/<%\s*(\w+)\s*%>/$$param{$1}/ge;

    my $result = 1;

    $smtp->mail("rts+$$param{id}\@$$param{domain}");
my $msg = $smtp->message();
$msg =~ s/\s+$//s;
$msg =~ s/[\r\n]+/ /s;

    if ($smtp->status() != 2)
    {
        $result = -2; # abort this connection
$MAIL{$smtp->code()} ||= $msg; # track response codes
#out("MAIL $$param{id}: ", $smtp->code(), " '$msg'");
        goto SMTP_RESET;
    }

    $smtp->to($$param{email}, {Notify => ['FAILURE'], SkipBad => 1});
$msg = $smtp->message();
$msg =~ s/\s+$//s;
$msg =~ s/[\r\n]+/ /s;

    if ($smtp->status() != 2)
    {
        $result = -2 if $smtp->status() == 4; # abort this connection
$RCPT{$smtp->code()} ||= $msg; # track response codes
        $result = ($smtp->code() =~ /^(?:501|511|550|551|553|554|555)$/ ? 2 : 3);
#out("RCPT <$$param{email}>: ", $smtp->code(), " '$msg'");
        goto SMTP_RESET;
    }

    $result = $smtp->data($template);
    $result = 0 unless $smtp->status() == 2 || $smtp->status() == 3;

    SMTP_RESET:
    $smtp->reset() unless $smtp->code() == 421;

    $result = -1 if $smtp->code() =~ /^(?:421|599|000)$/;

    return $result;
}

sub text_wrap
{
    my $text = shift;
    my $wrap;
    $text .= "\n" unless $text =~ /\n$/;

    my ($len, $nl) = (78, undef);

    while ($text !~ /^\s*$/)
    {
        $text =~ s/^([^\n]{0,$len})\s+// or
        $text =~ s/^([^\n]{$len,})\s+//;

        $wrap .= "$nl$1";
        $nl ||= "\n";
    }

    return $wrap;
}

sub domain
{
    my $ip = shift;
    my $host;

    my @domain = qw(
        start-a-mortgage-price-war.com
        compare-refi-rates.com
        start-a-refi-price-war.com
        compare-refinance-rates.com
        start-a-refinance-price-war.com
        great-refinance-rates.com
        great-refi-rates.com
        todays-best-mortgage-deals.com
        todays-best-refi-rates.com
    );

    eval
    {
        local $SIG{ALRM} = sub {die "ALRM\n"};
        alarm(2);
        $host = gethostbyaddr(pack('C4',split(/\./, $ip)), Socket::AF_INET());
        alarm(0);
    };

    return $host if $host && grep(/^$host$/, @domain) > 0;
    return $domain[int(rand(scalar(@domain)))];
}

sub from
{
    my @user = qw(
        getaloan
        newloans
        greatdeals
        ratecompare
        ratecheck
        customerservice
        support
        bestprice
        pricewar
        shop
        getadeal
        mortgagepro
        refipro
        refinancepro
        yourbestdeal
        priceslasher
        ratecutter
        lowrate
    );
    return $user[int(rand(scalar(@user)))];
}

sub subject
{
    my $param = shift;
    my $i;

    my @subject = ('We have hungry bankers in <%state_long%> looking to help you.',
                   'Is your mortgage too high <%location%>',
                   'You don\'t have the best home loan <%location%>',
                   'When does your mortgage adjust up <%location%>?',
                   'When does your mortgage go up on <%location%>?',
                   'Get out of your adjustable mortgage before it breaks your bank',
                   'Do you know the five secrets your mortgage banker is hiding from you?',
                   'Is your mortgage about to explode on you?',
                   'Do you have a poison mortgage?',
                   'Do your mortgage payments hurt?',
                   'When does your mortgage adjust up?',
                   'When does your mortgage go up?',
                   'We have hungry bankers looking to help you.',
                   'Is your mortgage the best you can do?',
                   'Can I get you a better home loan?',
                   'Is your home loan about to explode on you?',
                   'When does your home loan adjust up?',
                   'When does your home loan go up?',
                   'Is your home loan the best you can do?',
                   'Do you want to lower your mortgage payments?',
                   'Are your mortgage payments too high?',
                   'Refinance your mortgage.');

    if ($$param{address})
    {
        $$param{location} = "at $$param{address}";
    }
    elsif ($$param{city})
    {
        $$param{location} = "in $$param{city}";
    }

    while (1)
    {
        $i = int(rand(scalar(@subject)));
        next if ($i == 0 && !$$param{state}) || ($i > 0 && $i < 5 && !$$param{location});

        $$param{subject} = ($$param{first_name} ? "$$param{first_name}: " : '') . $subject[$i];
        $$param{subject} =~ s/<%(\w+)%>/$$param{$1}/e;
        return;
    }
}

sub template
{
    my $param = shift;
    my @option = (0);

    if ($$param{address})
    {
        push @option, 1;
        push @option, 3 if $$param{state};
        push @option, 4 if $$param{city} || $$param{zip};
        push @option, 5 if $$param{city} || $$param{state};
    }
    elsif ($$param{city} || $$param{state})
    {
        push @option, 2;
    }

    return $option[0] if @option == 1;
    return $option[int(rand(scalar(@option)))];
}

my @cycle_list;
my $cycle_idx = -1;
my $default_gateway = '208.76.255.9';
my @route_del = qw(/sbin/route del default gw);
my @route_add = qw(/sbin/route add default gw);

sub cycle_data
{
    my $ip;

    cmf::db::begin("dbi:SQLite:dbname=$cmf::CMF_BASE/conf/config.db") or return;

    my $fetch = cmf::db::select("select ip from ip_manage where ip like '%.2' and ip like '208.%' order by ip desc", \$ip); # xxx added order by to start with unused addresses

    while (&$fetch())
    {
        $ip =~ s/\.\d+$//;

        foreach (2..254)
        {
            cmf::db::get("select id from ip_manage where ip = '$ip.$_'") or next;
            push @cycle_list, [$ip, $_];
        }
    }

    cmf::db::end();
}

# manage ip cycling

sub cycle_init
{
    return if $cycle_idx >= 0;
    $cycle_idx = 0;
    `iptables -t nat -F POSTROUTING`;
}

sub cycle_ip
{
    cycle_restore() if $cycle_idx > $#cycle_list;
    cycle_init() if $cycle_idx < 0;

    my $current;

    if ($cycle_idx > 0)
    {
        $current = $cycle_list[$cycle_idx - 1];
        `iptables -t nat -F POSTROUTING`;
    }

    my $new = $cycle_list[$cycle_idx++];

    if ($current && $$current[0] ne $$new[0])
    {
        system(@route_del, "$$current[0].1");
        system(@route_add, "$$new[0].1");
    }
    elsif ($cycle_idx == 1)
    {
        system(@route_del, $default_gateway);
        system(@route_add, "$$new[0].1");
    }

    `iptables -t nat -A POSTROUTING -p tcp -o eth0 --dport 25 -j SNAT --to-source $$new[0].$$new[1]`;

    return "$$new[0].$$new[1]";
}

sub cycle_restore
{
    return unless $cycle_idx >= 0;

    if ($cycle_idx > 0)
    {
        my $current = $cycle_list[$cycle_idx - 1];
        `iptables -t nat -F POSTROUTING`;
        system(@route_del, "$$current[0].1");
    }

    system(@route_add, $default_gateway);

    $cycle_idx = -1;

    return;
}

# epoll routines used to manage the subprocesses

#my $EPOLLIN       = 1;
#my $EPOLL_CTL_ADD = 1;
#my $EPOLL_CTL_DEL = 2;
#my $syscall_epoll_create = 254;
#my $syscall_epoll_ctl    = 255;
#my $syscall_epoll_wait   = 256;
my $epoll_wait_size;

sub epoll_create
{
    return syscall(254, 100);
}

# epoll_ctl
# ARGS: (epfd, op, fd, events_mask)
sub epoll_ctl
{
    return if syscall(255, $_[0] + 0, $_[1], $_[2] + 0, pack('LLL', $_[3], $_[2], 0));

    if ($_[1] == $EPOLL_CTL_ADD)
    {
        $epoll_wait_size++;
    }
    elsif ($_[1] == $EPOLL_CTL_DEL)
    {
        $epoll_wait_size--;
    }

    return 1;
}

# epoll_wait
# ARGS: (epfd, timeout (milliseconds))
# returns: undef or [$fd, $event]

sub epoll_wait
{
    return unless $epoll_wait_size;
    my $epoll_wait_event = "\0" x 12;

    my $count = syscall(256, $_[0] + 0, $epoll_wait_event, 1, $_[1] + 0);

    return if $count < 1;

    my @list;

    @list[1, 0] = unpack('LL', substr($epoll_wait_event, 0, 8));

    return \@list;
}

sub pipe_pair
{
    my ($child_pipe, $parent_pipe);

    socketpair($child_pipe, $parent_pipe, Socket::AF_UNIX(), Socket::SOCK_STREAM(), Socket::PF_UNSPEC()) or  die "socketpair: $!";
    select((select($child_pipe), $| = 1)[0]); # $sock->autoflush(1);
    select((select($parent_pipe), $| = 1)[0]); # $sock->autoflush(1);

    return ($child_pipe, $parent_pipe);
}

sub _fileno
{
    my $fd = shift;
    return unless defined($fd);
    $fd = $$fd[0] if ref($fd) eq 'ARRAY';
    ($fd =~ /^\d+$/) ? $fd : fileno($fd);
}

sub out
{
    print STDERR "$$: ", @_, "\n";
}

END
{
    foreach (sort(keys(%MAIL)))
    {
        print STDERR "MAIL CODE $_: '$MAIL{$_}'\n";
    }

    foreach (sort(keys(%RCPT)))
    {
        print STDERR "RCPT CODE $_: '$RCPT{$_}'\n";
    }
}

__END__

http://iptables-tutorial.frozentux.net/iptables-tutorial.html
http://linux.about.com/od/commands/l/blcmdl8_iptable.htm

Table 11-17. SNAT target options
Option  --to-source
Example
iptables -t nat -A POSTROUTING -p tcp -o eth0 -j SNAT --to-source 194.236.50.155-194.236.50.160:1024-32000
Explanation
The --to-source option is used to specify which source the packet should use.
This option, at its simplest, takes one IP address which we want to use for the source IP address in the IP header.
If we want to balance between several IP addresses, we can use a range of IP addresses, separated by a hyphen.
The --to--source IP numbers could then, for instance, be something like in the above example: 194.236.50.155-194.236.50.160.
The source IP for each stream that we open would then be allocated randomly from these, and a single stream would always use the same IP address for all packets within that stream.
We can also specify a range of ports to be used by SNAT. All the source ports would then be confined to the ports specified.
The port bit of the rule would then look like in the example above, :1024-32000. This is only valid if -p tcp or -p udp was specified somewhere in the match of the rule in question.
iptables will always try to avoid making any port alterations if possible, but if two hosts try to use the same ports, iptables will map one of them to another port.
If no port range is specified, then if they're needed, all source ports below 512 will be mapped to other ports below 512. Those between source ports 512 and 1023 will be mapped to ports below 1024.
All other ports will be mapped to 1024 or above. As previously stated, iptables will always try to maintain the source ports used by the actual workstation making the connection.
Note that this has nothing to do with destination ports, so if a client tries to make contact with an HTTP server outside the firewall, it will not be mapped to the FTP control port.
===
http://tools.ietf.org/html/rfc2821

CONNECTION ESTABLISHMENT
S: 220
E: 554
EHLO or HELO
S: 250
E: 504, 550
VRFY
S: 250, 251, 252
E: 550, 551, 553, 502, 504
MAIL
S: 250
E: 451, 452, 503, 550, 552, 553
RCPT
S: 250, 251 (but see section 3.4 for discussion of 251 and 551)
E: 550, 551, 552, 553, 450, 451, 452, 503
DATA
I: 354 -> data -> S: 250
E: 451, 452, 552, 554
E: 451, 503, 554
RSET
S: 250
HELP
S: 211, 214
E: 502, 504
QUIT
S: 221

non-SMTP RFC response codes encountered
211 System status, or system help reply
214 Help message (Information on how to use the receiver or the meaning of a particular non-standard command; this reply is useful only to the human user)
220 <domain> Service ready
221 <domain> Service closing transmission channel
250 Requested mail action okay, completed
251 User not local; will forward to <forward-path> (See section 3.4)
252 Cannot VRFY user, but will accept message and attempt delivery (See section 3.5.3)
354 Start mail input; end with <CRLF>.<CRLF>
421 <domain> Service not available, closing transmission channel (This may be a reply to any command if the service knows it must shut down)
450 Requested mail action not taken: mailbox unavailable (e.g., mailbox busy)
451 Requested action aborted: local error in processing
452 Requested action not taken: insufficient system storage
500 Syntax error, command unrecognized (This may include errors such as command line too long)
501 Syntax error in parameters or arguments
502 Command not implemented (see section 4.2.4)
503 Bad sequence of commands
504 Command parameter not implemented
550 Requested action not taken: mailbox unavailable (e.g., mailbox not found, no access, or command rejected for policy reasons)
551 User not local; please try <forward-path> (See section 3.4)
552 Requested mail action aborted: exceeded storage allocation
553 Requested action not taken: mailbox name not allowed (e.g., mailbox syntax incorrect)
554 Transaction failed  (Or, in the case of a connection-opening response, "No SMTP service here")
