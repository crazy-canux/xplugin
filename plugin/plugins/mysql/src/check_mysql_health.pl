#! /usr/bin/perl -w
# nagios: -epn

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );
package DBD::MySQL::Server::Instance::Innodb;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    internals => undef,
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::innodb/) {
    $self->{internals} =
        DBD::MySQL::Server::Instance::Innodb::Internals->new(%params);
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if ($params{mode} =~ /server::instance::innodb/) {
    $self->{internals}->nagios(%params);
    $self->merge_nagios($self->{internals});
  }
}


package DBD::MySQL::Server::Instance::Innodb::Internals;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance::Innodb);

our $internals; # singleton, nur ein einziges mal instantiierbar

sub new {
  my $class = shift;
  my %params = @_;
  unless ($internals) {
    $internals = {
      handle => $params{handle},
      bufferpool_hitrate => undef,
      wait_free => undef,
      log_waits => undef,
      have_innodb => undef,
      warningrange => $params{warningrange},
      criticalrange => $params{criticalrange},
    };
    bless($internals, $class);
    $internals->init(%params);
  }
  return($internals);
}

sub init {
  my $self = shift;
  my %params = @_;
  my $dummy;
  $self->debug("enter init");
  $self->init_nagios();
  ($dummy, $self->{have_innodb}) 
      = $self->{handle}->fetchrow_array(q{
      SHOW VARIABLES LIKE 'have_innodb'
  });
  if ($self->{have_innodb} eq "NO") {
    $self->add_nagios_critical("the innodb engine has a problem (have_innodb=no)");
  } elsif ($self->{have_innodb} eq "DISABLED") {
    # add_nagios_ok later
  } elsif ($params{mode} =~ /server::instance::innodb::bufferpool::hitrate/) {
    ($dummy, $self->{bufferpool_reads}) 
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Innodb_buffer_pool_reads'
    });
    ($dummy, $self->{bufferpool_read_requests}) 
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Innodb_buffer_pool_read_requests'
    });
    if (! defined $self->{bufferpool_reads}) {
      $self->add_nagios_critical("no innodb buffer pool info available");
    } else {
      $self->valdiff(\%params, qw(bufferpool_reads
          bufferpool_read_requests));
      $self->{bufferpool_hitrate_now} =
          $self->{delta_bufferpool_read_requests} > 0 ?
          100 - (100 * $self->{delta_bufferpool_reads} / 
              $self->{delta_bufferpool_read_requests}) : 100;
      $self->{bufferpool_hitrate} =
          $self->{bufferpool_read_requests} > 0 ?
          100 - (100 * $self->{bufferpool_reads} /
              $self->{bufferpool_read_requests}) : 100;
    }
  } elsif ($params{mode} =~ /server::instance::innodb::bufferpool::waitfree/) {
    ($dummy, $self->{bufferpool_wait_free})
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Innodb_buffer_pool_wait_free'
    });
    if (! defined $self->{bufferpool_wait_free}) {
      $self->add_nagios_critical("no innodb buffer pool info available");
    } else {
      $self->valdiff(\%params, qw(bufferpool_wait_free));
      $self->{bufferpool_wait_free_rate} =
          $self->{delta_bufferpool_wait_free} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /server::instance::innodb::logwaits/) {
    ($dummy, $self->{log_waits})
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Innodb_log_waits'
    });
    if (! defined $self->{log_waits}) {
      $self->add_nagios_critical("no innodb log info available");
    } else {
      $self->valdiff(\%params, qw(log_waits));
      $self->{log_waits_rate} =
          $self->{delta_log_waits} / $self->{delta_timestamp};
    }
  } elsif ($params{mode} =~ /server::instance::innodb::needoptimize/) {
#fragmentation=$(($datafree * 100 / $datalength))

#http://www.electrictoolbox.com/optimize-tables-mysql-php/
    my  @result = $self->{handle}->fetchall_array(q{
SHOW TABLE STATUS WHERE Data_free / Data_length > 0.1 AND Data_free > 102400
});
printf "%s\n", Data::Dumper::Dumper(\@result);

  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  my $now = $params{lookback} ? '_now' : '';
  if ($self->{have_innodb} eq "DISABLED") {
    $self->add_nagios_ok("the innodb engine has been disabled");
  } elsif (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::innodb::bufferpool::hitrate/) {
      my $refkey = 'bufferpool_hitrate'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "99:", "95:"),
              sprintf "innodb buffer pool hitrate at %.2f%%", $self->{$refkey});
      $self->add_perfdata(sprintf "bufferpool_hitrate=%.2f%%;%s;%s;0;100",
          $self->{bufferpool_hitrate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "bufferpool_hitrate_now=%.2f%%",
          $self->{bufferpool_hitrate_now});
    } elsif ($params{mode} =~ /server::instance::innodb::bufferpool::waitfree/) {
      $self->add_nagios(
          $self->check_thresholds($self->{bufferpool_wait_free_rate}, "1", "10"),
          sprintf "%ld innodb buffer pool waits in %ld seconds (%.4f/sec)",
          $self->{delta_bufferpool_wait_free}, $self->{delta_timestamp},
          $self->{bufferpool_wait_free_rate});
      $self->add_perfdata(sprintf "bufferpool_free_waits_rate=%.4f;%s;%s;0;100",
          $self->{bufferpool_wait_free_rate},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::innodb::logwaits/) {
      $self->add_nagios(
          $self->check_thresholds($self->{log_waits_rate}, "1", "10"),
          sprintf "%ld innodb log waits in %ld seconds (%.4f/sec)",
          $self->{delta_log_waits}, $self->{delta_timestamp},
          $self->{log_waits_rate});
      $self->add_perfdata(sprintf "innodb_log_waits_rate=%.4f;%s;%s;0;100",
          $self->{log_waits_rate},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}




package DBD::MySQL::Server::Instance::MyISAM;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    internals => undef,
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::myisam/) {
    $self->{internals} =
        DBD::MySQL::Server::Instance::MyISAM::Internals->new(%params);
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if ($params{mode} =~ /server::instance::myisam/) {
    $self->{internals}->nagios(%params);
    $self->merge_nagios($self->{internals});
  }
}


package DBD::MySQL::Server::Instance::MyISAM::Internals;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance::MyISAM);

our $internals; # singleton, nur ein einziges mal instantiierbar

sub new {
  my $class = shift;
  my %params = @_;
  unless ($internals) {
    $internals = {
      handle => $params{handle},
      keycache_hitrate => undef,
      warningrange => $params{warningrange},
      criticalrange => $params{criticalrange},
    };
    bless($internals, $class);
    $internals->init(%params);
  }
  return($internals);
}

sub init {
  my $self = shift;
  my %params = @_;
  my $dummy;
  $self->debug("enter init");
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::myisam::keycache::hitrate/) {
    ($dummy, $self->{key_reads})
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Key_reads'
    });
    ($dummy, $self->{key_read_requests})
        = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Key_read_requests'
    });
    if (! defined $self->{key_read_requests}) {
      $self->add_nagios_critical("no myisam keycache info available");
    } else {
      $self->valdiff(\%params, qw(key_reads key_read_requests));
      $self->{keycache_hitrate} =
          $self->{key_read_requests} > 0 ?
          100 - (100 * $self->{key_reads} /
              $self->{key_read_requests}) : 100;
      $self->{keycache_hitrate_now} =
          $self->{delta_key_read_requests} > 0 ?
          100 - (100 * $self->{delta_key_reads} /
              $self->{delta_key_read_requests}) : 100;
    }
  } elsif ($params{mode} =~ /server::instance::myisam::sonstnochwas/) {
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::myisam::keycache::hitrate/) {
      my $refkey = 'keycache_hitrate'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "99:", "95:"),
              sprintf "myisam keycache hitrate at %.2f%%", $self->{$refkey});
      $self->add_perfdata(sprintf "keycache_hitrate=%.2f%%;%s;%s",
          $self->{keycache_hitrate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "keycache_hitrate_now=%.2f%%;%s;%s",
          $self->{keycache_hitrate_now},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


package DBD::MySQL::Server::Instance::Replication;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    internals => undef,
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::replication/) {
    $self->{internals} =
        DBD::MySQL::Server::Instance::Replication::Internals->new(%params);
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if ($params{mode} =~ /server::instance::replication/) {
    $self->{internals}->nagios(%params);
    $self->merge_nagios($self->{internals});
  }
}


package DBD::MySQL::Server::Instance::Replication::Internals;

use strict;

our @ISA = qw(DBD::MySQL::Server::Instance::Replication);

our $internals; # singleton, nur ein einziges mal instantiierbar

sub new {
  my $class = shift;
  my %params = @_;
  unless ($internals) {
    $internals = {
      handle => $params{handle},
      seconds_behind_master => undef,
      slave_io_running => undef,
      slave_sql_running => undef,
      warningrange => $params{warningrange},
      criticalrange => $params{criticalrange},
    };
    bless($internals, $class);
    $internals->init(%params);
  }
  return($internals);
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->debug("enter init");
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::replication::slavelag/) {
    # "show slave status", "Seconds_Behind_Master"
    my $slavehash = $self->{handle}->selectrow_hashref(q{
            SHOW SLAVE STATUS
        });
    if ((! defined $slavehash->{Seconds_Behind_Master}) && 
        (lc $slavehash->{Slave_IO_Running} eq 'no')) {
      $self->add_nagios_critical(
          "unable to get slave lag, because io thread is not running");
    } elsif (! defined $slavehash->{Seconds_Behind_Master}) {
      $self->add_nagios_critical(sprintf "unable to get replication info%s",
          $self->{handle}->{errstr} ? $self->{handle}->{errstr} : "");
    } else {
      $self->{seconds_behind_master} = $slavehash->{Seconds_Behind_Master};
    }
  } elsif ($params{mode} =~ /server::instance::replication::slaveiorunning/) {
    # "show slave status", "Slave_IO_Running"
    my $slavehash = $self->{handle}->selectrow_hashref(q{
            SHOW SLAVE STATUS
        });
    if (! defined $slavehash->{Slave_IO_Running}) {
      $self->add_nagios_critical(sprintf "unable to get replication info%s",
          $self->{handle}->{errstr} ? $self->{handle}->{errstr} : "");
    } else {
      $self->{slave_io_running} = $slavehash->{Slave_IO_Running};
    }
  } elsif ($params{mode} =~ /server::instance::replication::slavesqlrunning/) {
    # "show slave status", "Slave_SQL_Running"
    my $slavehash = $self->{handle}->selectrow_hashref(q{
            SHOW SLAVE STATUS
        });
    if (! defined $slavehash->{Slave_SQL_Running}) {
      $self->add_nagios_critical(sprintf "unable to get replication info%s",
          $self->{handle}->{errstr} ? $self->{handle}->{errstr} : "");
    } else {
      $self->{slave_sql_running} = $slavehash->{Slave_SQL_Running};
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::replication::slavelag/) {
      $self->add_nagios(
          $self->check_thresholds($self->{seconds_behind_master}, "10", "20"),
          sprintf "Slave is %d seconds behind master",
          $self->{seconds_behind_master});
      $self->add_perfdata(sprintf "slave_lag=%d;%s;%s",
          $self->{seconds_behind_master},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::replication::slaveiorunning/) {
      if (lc $self->{slave_io_running} eq "yes") {
        $self->add_nagios_ok("Slave io is running");
      } else {
        $self->add_nagios_critical("Slave io is not running");
      }
    } elsif ($params{mode} =~ /server::instance::replication::slavesqlrunning/) {
      if (lc $self->{slave_sql_running} eq "yes") {
        $self->add_nagios_ok("Slave sql is running");
      } else {
        $self->add_nagios_critical("Slave sql is not running");
      }
    }
  }
}



package DBD::MySQL::Server::Instance;

use strict;

our @ISA = qw(DBD::MySQL::Server);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    uptime => $params{uptime},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    threads_connected => undef,
    threads_created => undef,
    connections => undef,
    threadcache_hitrate => undef,
    querycache_hitrate => undef,
    lowmem_prunes_per_sec => undef,
    slow_queries_per_sec => undef,
    longrunners => undef,
    tablecache_hitrate => undef,
    index_usage => undef,
    engine_innodb => undef,
    engine_myisam => undef,
    replication => undef,
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  my $dummy;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::connectedthreads/) {
    ($dummy, $self->{threads_connected}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Threads_connected'
    });
  } elsif ($params{mode} =~ /server::instance::createdthreads/) {
    ($dummy, $self->{threads_created}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Threads_created'
    });
    $self->valdiff(\%params, qw(threads_created));
    $self->{threads_created_per_sec} = $self->{delta_threads_created} /
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::runningthreads/) {
    ($dummy, $self->{threads_running}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Threads_running'
    });
  } elsif ($params{mode} =~ /server::instance::cachedthreads/) {
    ($dummy, $self->{threads_cached}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Threads_cached'
    });
  } elsif ($params{mode} =~ /server::instance::abortedconnects/) {
    ($dummy, $self->{connects_aborted}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Aborted_connects'
    });
    $self->valdiff(\%params, qw(connects_aborted));
    $self->{connects_aborted_per_sec} = $self->{delta_connects_aborted} /
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::abortedclients/) {
    ($dummy, $self->{clients_aborted}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Aborted_clients'
    });
    $self->valdiff(\%params, qw(clients_aborted));
    $self->{clients_aborted_per_sec} = $self->{delta_clients_aborted} /
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::threadcachehitrate/) {
    ($dummy, $self->{threads_created}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Threads_created'
    });
    ($dummy, $self->{connections}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Connections'
    });
    $self->valdiff(\%params, qw(threads_created connections));
    if ($self->{delta_connections} > 0) {
      $self->{threadcache_hitrate_now} = 
          100 - ($self->{delta_threads_created} * 100.0 /
          $self->{delta_connections});
    } else {
      $self->{threadcache_hitrate_now} = 100;
    }
    $self->{threadcache_hitrate} = 100 - 
        ($self->{threads_created} * 100.0 / $self->{connections});
    $self->{connections_per_sec} = $self->{delta_connections} /
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::querycachehitrate/) {
    ($dummy, $self->{com_select}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Com_select'
    });
    ($dummy, $self->{qcache_hits}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Qcache_hits'
    });
    #    SHOW VARIABLES WHERE Variable_name = 'have_query_cache' for 5.x, but LIKE is compatible
    ($dummy, $self->{have_query_cache}) = $self->{handle}->fetchrow_array(q{
        SHOW VARIABLES LIKE 'have_query_cache'
    });
    #    SHOW VARIABLES WHERE Variable_name = 'query_cache_size'
    ($dummy, $self->{query_cache_size}) = $self->{handle}->fetchrow_array(q{
        SHOW VARIABLES LIKE 'query_cache_size'
    });
    $self->valdiff(\%params, qw(com_select qcache_hits));
    $self->{querycache_hitrate_now} = 
        ($self->{delta_com_select} + $self->{delta_qcache_hits}) > 0 ?
        100 * $self->{delta_qcache_hits} /
            ($self->{delta_com_select} + $self->{delta_qcache_hits}) :
        0;
    $self->{querycache_hitrate} = 
        ($self->{com_select} + $self->{qcache_hits}) > 0 ?
        100 * $self->{qcache_hits} /
            ($self->{com_select} + $self->{qcache_hits}) :
        0;
    $self->{selects_per_sec} =
        $self->{delta_com_select} / $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::querycachelowmemprunes/) {
    ($dummy, $self->{lowmem_prunes}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Qcache_lowmem_prunes'
    });
    $self->valdiff(\%params, qw(lowmem_prunes));
    $self->{lowmem_prunes_per_sec} = $self->{delta_lowmem_prunes} / 
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::slowqueries/) {
    ($dummy, $self->{slow_queries}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Slow_queries'
    });
    $self->valdiff(\%params, qw(slow_queries));
    $self->{slow_queries_per_sec} = $self->{delta_slow_queries} / 
        $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::longprocs/) {
    if (DBD::MySQL::Server::return_first_server()->version_is_minimum("5.1")) {
      ($self->{longrunners}) = $self->{handle}->fetchrow_array(q{
          SELECT
              COUNT(*)
          FROM
              information_schema.processlist
          WHERE user <> 'replication' 
          AND id <> CONNECTION_ID() 
          AND time > 60 
          AND command <> 'Sleep'
      });
    } else {
      $self->{longrunners} = 0 if ! defined $self->{longrunners};
      foreach ($self->{handle}->fetchall_array(q{
          SHOW PROCESSLIST
      })) {
        my($id, $user, $host, $db, $command, $tme, $state, $info) = @{$_};
        if (($user ne 'replication') &&
            ($tme > 60) &&
            ($command ne 'Sleep')) {
          $self->{longrunners}++;
        }
      }
    }
  } elsif ($params{mode} =~ /server::instance::tablecachehitrate/) {
    ($dummy, $self->{open_tables}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Open_tables'
    });
    ($dummy, $self->{opened_tables}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Opened_tables'
    });
    if (DBD::MySQL::Server::return_first_server()->version_is_minimum("5.1.3")) {
      #      SHOW VARIABLES WHERE Variable_name = 'table_open_cache'
      ($dummy, $self->{table_cache}) = $self->{handle}->fetchrow_array(q{
          SHOW VARIABLES LIKE 'table_open_cache'
      });
    } else {
      #    SHOW VARIABLES WHERE Variable_name = 'table_cache'
      ($dummy, $self->{table_cache}) = $self->{handle}->fetchrow_array(q{
          SHOW VARIABLES LIKE 'table_cache'
      });
    }
    $self->{table_cache} ||= 0;
    #$self->valdiff(\%params, qw(open_tables opened_tables table_cache));
    # _now ist hier sinnlos, da opened_tables waechst, aber open_tables wieder 
    # schrumpfen kann weil tabellen geschlossen werden.
    if ($self->{opened_tables} != 0 && $self->{table_cache} != 0) {
      $self->{tablecache_hitrate} = 
          100 * $self->{open_tables} / $self->{opened_tables};
      $self->{tablecache_fillrate} = 
          100 * $self->{open_tables} / $self->{table_cache};
    } elsif ($self->{opened_tables} == 0 && $self->{table_cache} != 0) {
      $self->{tablecache_hitrate} = 100;
      $self->{tablecache_fillrate} = 
          100 * $self->{open_tables} / $self->{table_cache};
    } else {
      $self->{tablecache_hitrate} = 0;
      $self->{tablecache_fillrate} = 0;
      $self->add_nagios_critical("no table cache");
    }
  } elsif ($params{mode} =~ /server::instance::tablelockcontention/) {
    ($dummy, $self->{table_locks_waited}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Table_locks_waited'
    });
    ($dummy, $self->{table_locks_immediate}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Table_locks_immediate'
    });
    $self->valdiff(\%params, qw(table_locks_waited table_locks_immediate));
    $self->{table_lock_contention} = 
        ($self->{table_locks_waited} + $self->{table_locks_immediate}) > 0 ?
        100 * $self->{table_locks_waited} / 
        ($self->{table_locks_waited} + $self->{table_locks_immediate}) :
        100;
    $self->{table_lock_contention_now} = 
        ($self->{delta_table_locks_waited} + $self->{delta_table_locks_immediate}) > 0 ?
        100 * $self->{delta_table_locks_waited} / 
        ($self->{delta_table_locks_waited} + $self->{delta_table_locks_immediate}) :
        100;
  } elsif ($params{mode} =~ /server::instance::tableindexusage/) {
    # http://johnjacobm.wordpress.com/2007/06/
    # formula for calculating the percentage of full table scans
    ($dummy, $self->{handler_read_first}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_first'
    });
    ($dummy, $self->{handler_read_key}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_key'
    });
    ($dummy, $self->{handler_read_next}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_next'
    });
    ($dummy, $self->{handler_read_prev}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_prev'
    });
    ($dummy, $self->{handler_read_rnd}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_rnd'
    });
    ($dummy, $self->{handler_read_rnd_next}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Handler_read_rnd_next'
    });
    $self->valdiff(\%params, qw(handler_read_first handler_read_key
        handler_read_next handler_read_prev handler_read_rnd
        handler_read_rnd_next));
    my $delta_reads = $self->{delta_handler_read_first} +
        $self->{delta_handler_read_key} +
        $self->{delta_handler_read_next} +
        $self->{delta_handler_read_prev} +
        $self->{delta_handler_read_rnd} +
        $self->{delta_handler_read_rnd_next};
    my $reads = $self->{handler_read_first} +
        $self->{handler_read_key} +
        $self->{handler_read_next} +
        $self->{handler_read_prev} +
        $self->{handler_read_rnd} +
        $self->{handler_read_rnd_next};
    $self->{index_usage_now} = ($delta_reads == 0) ? 0 :
        100 - (100.0 * ($self->{delta_handler_read_rnd} +
        $self->{delta_handler_read_rnd_next}) /
        $delta_reads);
    $self->{index_usage} = ($reads == 0) ? 0 :
        100 - (100.0 * ($self->{handler_read_rnd} +
        $self->{handler_read_rnd_next}) /
        $reads);
  } elsif ($params{mode} =~ /server::instance::tabletmpondisk/) {
    ($dummy, $self->{created_tmp_tables}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Created_tmp_tables'
    });
    ($dummy, $self->{created_tmp_disk_tables}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Created_tmp_disk_tables'
    });
    $self->valdiff(\%params, qw(created_tmp_tables created_tmp_disk_tables));
    $self->{pct_tmp_on_disk} = $self->{created_tmp_tables} > 0 ?
        100 * $self->{created_tmp_disk_tables} / $self->{created_tmp_tables} :
        100;
    $self->{pct_tmp_on_disk_now} = $self->{delta_created_tmp_tables} > 0 ?
        100 * $self->{delta_created_tmp_disk_tables} / $self->{delta_created_tmp_tables} :
        100;
  } elsif ($params{mode} =~ /server::instance::openfiles/) {
    ($dummy, $self->{open_files_limit}) = $self->{handle}->fetchrow_array(q{
        SHOW VARIABLES LIKE 'open_files_limit'
    });
    ($dummy, $self->{open_files}) = $self->{handle}->fetchrow_array(q{
        SHOW /*!50000 global */ STATUS LIKE 'Open_files'
    });
    $self->{pct_open_files} = 100 * $self->{open_files} / $self->{open_files_limit};
  } elsif ($params{mode} =~ /server::instance::needoptimize/) {
    $self->{fragmented} = [];
    #http://www.electrictoolbox.com/optimize-tables-mysql-php/
    my  @result = $self->{handle}->fetchall_array(q{
        SHOW TABLE STATUS
    });
    foreach (@result) {
      my ($name, $engine, $data_length, $data_free) =
          ($_->[0], $_->[1], $_->[6 ], $_->[9]);
      next if ($params{name} && $params{name} ne $name);
      my $fragmentation = $data_length ? $data_free * 100 / $data_length : 0;
      push(@{$self->{fragmented}},
          [$name, $fragmentation, $data_length, $data_free]);
    }
  } elsif ($params{mode} =~ /server::instance::myisam/) {
    $self->{engine_myisam} = DBD::MySQL::Server::Instance::MyISAM->new(
        %params
    );
  } elsif ($params{mode} =~ /server::instance::innodb/) {
    $self->{engine_innodb} = DBD::MySQL::Server::Instance::Innodb->new(
        %params
    );
  } elsif ($params{mode} =~ /server::instance::replication/) {
    $self->{replication} = DBD::MySQL::Server::Instance::Replication->new(
        %params
    );
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::connectedthreads/) {
      $self->add_nagios(
          $self->check_thresholds($self->{threads_connected}, 10, 20),
          sprintf "%d client connection threads", $self->{threads_connected});
      $self->add_perfdata(sprintf "threads_connected=%d;%d;%d",
          $self->{threads_connected},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::createdthreads/) {
      $self->add_nagios(
          $self->check_thresholds($self->{threads_created_per_sec}, 10, 20),
          sprintf "%.2f threads created/sec", $self->{threads_created_per_sec});
      $self->add_perfdata(sprintf "threads_created_per_sec=%.2f;%.2f;%.2f",
          $self->{threads_created_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::runningthreads/) {
      $self->add_nagios(
          $self->check_thresholds($self->{threads_running}, 10, 20),
          sprintf "%d running threads", $self->{threads_running});
      $self->add_perfdata(sprintf "threads_running=%d;%d;%d",
          $self->{threads_running},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::cachedthreads/) {
      $self->add_nagios(
          $self->check_thresholds($self->{threads_cached}, 10, 20),
          sprintf "%d cached threads", $self->{threads_cached});
      $self->add_perfdata(sprintf "threads_cached=%d;%d;%d",
          $self->{threads_cached},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::abortedconnects/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connects_aborted_per_sec}, 1, 5),
          sprintf "%.2f aborted connections/sec", $self->{connects_aborted_per_sec});
      $self->add_perfdata(sprintf "connects_aborted_per_sec=%.2f;%.2f;%.2f",
          $self->{connects_aborted_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::abortedclients/) {
      $self->add_nagios(
          $self->check_thresholds($self->{clients_aborted_per_sec}, 1, 5),
          sprintf "%.2f aborted (client died) connections/sec", $self->{clients_aborted_per_sec});
      $self->add_perfdata(sprintf "clients_aborted_per_sec=%.2f;%.2f;%.2f",
          $self->{clients_aborted_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::threadcachehitrate/) {
      my $refkey = 'threadcache_hitrate'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "90:", "80:"),
          sprintf "thread cache hitrate %.2f%%", $self->{$refkey});
      $self->add_perfdata(sprintf "thread_cache_hitrate=%.2f%%;%s;%s",
          $self->{threadcache_hitrate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "thread_cache_hitrate_now=%.2f%%",
          $self->{threadcache_hitrate_now});
      $self->add_perfdata(sprintf "connections_per_sec=%.2f",
          $self->{connections_per_sec});
    } elsif ($params{mode} =~ /server::instance::querycachehitrate/) {
      my $refkey = 'querycache_hitrate'.($params{lookback} ? '_now' : '');
      if ((lc $self->{have_query_cache} eq 'yes') && ($self->{query_cache_size})) {
        $self->add_nagios(
            $self->check_thresholds($self->{$refkey}, "90:", "80:"),
            sprintf "query cache hitrate %.2f%%", $self->{$refkey});
      } else {
        $self->check_thresholds($self->{$refkey}, "90:", "80:");
        $self->add_nagios_ok(
            sprintf "query cache hitrate %.2f%% (because it's turned off)",
            $self->{querycache_hitrate});
      }
      $self->add_perfdata(sprintf "qcache_hitrate=%.2f%%;%s;%s",
          $self->{querycache_hitrate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "qcache_hitrate_now=%.2f%%",
          $self->{querycache_hitrate_now});
      $self->add_perfdata(sprintf "selects_per_sec=%.2f",
          $self->{selects_per_sec});
    } elsif ($params{mode} =~ /server::instance::querycachelowmemprunes/) {
      $self->add_nagios(
          $self->check_thresholds($self->{lowmem_prunes_per_sec}, "1", "10"),
          sprintf "%d query cache lowmem prunes in %d seconds (%.2f/sec)",
          $self->{delta_lowmem_prunes}, $self->{delta_timestamp},
          $self->{lowmem_prunes_per_sec});
      $self->add_perfdata(sprintf "qcache_lowmem_prunes_rate=%.2f;%s;%s",
          $self->{lowmem_prunes_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::slowqueries/) {
      $self->add_nagios(
          $self->check_thresholds($self->{slow_queries_per_sec}, "0.1", "1"),
          sprintf "%d slow queries in %d seconds (%.2f/sec)",
          $self->{delta_slow_queries}, $self->{delta_timestamp},
          $self->{slow_queries_per_sec});
      $self->add_perfdata(sprintf "slow_queries_rate=%.2f%%;%s;%s",
          $self->{slow_queries_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::longprocs/) {
      $self->add_nagios(
          $self->check_thresholds($self->{longrunners}, 10, 20),
          sprintf "%d long running processes", $self->{longrunners});
      $self->add_perfdata(sprintf "long_running_procs=%d;%d;%d",
          $self->{longrunners},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::tablecachehitrate/) {
      if ($self->{tablecache_fillrate} < 95) {
        $self->add_nagios_ok(
            sprintf "table cache hitrate %.2f%%, %.2f%% filled",
                $self->{tablecache_hitrate},
                $self->{tablecache_fillrate});
        $self->check_thresholds($self->{tablecache_hitrate}, "99:", "95:");
      } else {
        $self->add_nagios(
            $self->check_thresholds($self->{tablecache_hitrate}, "99:", "95:"),
            sprintf "table cache hitrate %.2f%%", $self->{tablecache_hitrate});
      }
      $self->add_perfdata(sprintf "tablecache_hitrate=%.2f%%;%s;%s",
          $self->{tablecache_hitrate},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "tablecache_fillrate=%.2f%%",
          $self->{tablecache_fillrate});
    } elsif ($params{mode} =~ /server::instance::tablelockcontention/) {
      my $refkey = 'table_lock_contention'.($params{lookback} ? '_now' : '');
      if ($self->{uptime} > 10800) { # MySQL Bug #30599
        $self->add_nagios(
            $self->check_thresholds($self->{$refkey}, "1", "2"),
                sprintf "table lock contention %.2f%%", $self->{$refkey});
      } else {
        $self->check_thresholds($self->{$refkey}, "1", "2");
        $self->add_nagios_ok(
            sprintf "table lock contention %.2f%% (uptime < 10800)",
            $self->{$refkey});
      }
      $self->add_perfdata(sprintf "tablelock_contention=%.2f%%;%s;%s",
          $self->{table_lock_contention},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "tablelock_contention_now=%.2f%%",
          $self->{table_lock_contention_now});
    } elsif ($params{mode} =~ /server::instance::tableindexusage/) {
      my $refkey = 'index_usage'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "90:", "80:"),
              sprintf "index usage  %.2f%%", $self->{$refkey});
      $self->add_perfdata(sprintf "index_usage=%.2f%%;%s;%s",
          $self->{index_usage},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "index_usage_now=%.2f%%",
          $self->{index_usage_now});
    } elsif ($params{mode} =~ /server::instance::tabletmpondisk/) {
      my $refkey = 'pct_tmp_on_disk'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "25", "50"),
              sprintf "%.2f%% of %d tables were created on disk",
              $self->{$refkey}, $self->{delta_created_tmp_tables});
      $self->add_perfdata(sprintf "pct_tmp_table_on_disk=%.2f%%;%s;%s",
          $self->{pct_tmp_on_disk},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "pct_tmp_table_on_disk_now=%.2f%%",
          $self->{pct_tmp_on_disk_now});
    } elsif ($params{mode} =~ /server::instance::openfiles/) {
      $self->add_nagios(
          $self->check_thresholds($self->{pct_open_files}, 80, 95),
          sprintf "%.2f%% of the open files limit reached (%d of max. %d)",
              $self->{pct_open_files},
              $self->{open_files}, $self->{open_files_limit});
      $self->add_perfdata(sprintf "pct_open_files=%.3f%%;%.3f;%.3f",
          $self->{pct_open_files},
          $self->{warningrange},
          $self->{criticalrange});
      $self->add_perfdata(sprintf "open_files=%d;%d;%d",
          $self->{open_files},
          $self->{open_files_limit} * $self->{warningrange} / 100,
          $self->{open_files_limit} * $self->{criticalrange} / 100);
    } elsif ($params{mode} =~ /server::instance::needoptimize/) {
      foreach (@{$self->{fragmented}}) {
        $self->add_nagios(
            $self->check_thresholds($_->[1], 10, 25),
            sprintf "table %s is %.2f%% fragmented", $_->[0], $_->[1]);
        if ($params{name}) {
          $self->add_perfdata(sprintf "'%s_frag'=%.2f%%;%d;%d",
              $_->[0], $_->[1], $self->{warningrange}, $self->{criticalrange});
        }
      }
    } elsif ($params{mode} =~ /server::instance::myisam/) {
      $self->{engine_myisam}->nagios(%params);
      $self->merge_nagios($self->{engine_myisam});
    } elsif ($params{mode} =~ /server::instance::innodb/) {
      $self->{engine_innodb}->nagios(%params);
      $self->merge_nagios($self->{engine_innodb});
    } elsif ($params{mode} =~ /server::instance::replication/) {
      $self->{replication}->nagios(%params);
      $self->merge_nagios($self->{replication});
    }
  }
}



package DBD::MySQL::Server;

use strict;
use Time::HiRes;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;


{
  our $verbose = 0;
  our $scream = 0; # scream if something is not implemented
  our $access = "dbi"; # how do we access the database. 
  our $my_modules_dyn_dir = ""; # where we look for self-written extensions

  my @servers = ();
  my $initerrors = undef;

  sub add_server {
    push(@servers, shift);
  }

  sub return_servers {
    return @servers;
  }
  
  sub return_first_server() {
    return $servers[0];
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    access => $params{method} || 'dbi',
    hostname => $params{hostname},
    database => $params{database} || 'information_schema',
    port => $params{port},
    socket => $params{socket},
    username => $params{username},
    password => $params{password},
    mycnf => $params{mycnf},
    mycnfgroup => $params{mycnfgroup},
    timeout => $params{timeout},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    verbose => $params{verbose},
    report => $params{report},
    labelformat => $params{labelformat},
    version => 'unknown',
    instance => undef,
    handle => undef,
  };
  bless $self, $class;
  $self->init_nagios();
  if ($self->dbconnect(%params)) {
    ($self->{dummy}, $self->{version}) = $self->{handle}->fetchrow_array(
        #q{ SHOW VARIABLES WHERE Variable_name = 'version' }
        q{ SHOW VARIABLES LIKE 'version' }
    );
    $self->{version} = (split "-", $self->{version})[0];
    ($self->{dummy}, $self->{uptime}) = $self->{handle}->fetchrow_array(
        q{ SHOW STATUS LIKE 'Uptime' }
    );
    DBD::MySQL::Server::add_server($self);
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $params{handle} = $self->{handle};
  $params{uptime} = $self->{uptime};
  $self->set_global_db_thresholds(\%params);
  if ($params{mode} =~ /^server::instance/) {
    $self->{instance} = DBD::MySQL::Server::Instance->new(%params);
  } elsif ($params{mode} =~ /^server::sql/) {
    $self->set_local_db_thresholds(%params);
    if ($params{regexp}) {
      # sql output is treated as text
      if ($params{name2} eq $params{name}) {
        $self->add_nagios_unknown(sprintf "where's the regexp????");
      } else {
        $self->{genericsql} =
            $self->{handle}->fetchrow_array($params{selectname});
        if (! defined $self->{genericsql}) {
          $self->add_nagios_unknown(sprintf "got no valid response for %s",
              $params{selectname});
        }
      }
    } else {
      # sql output must be a number (or array of numbers)
      @{$self->{genericsql}} =
          $self->{handle}->fetchrow_array($params{selectname});
      if (! (defined $self->{genericsql} &&
          (scalar(grep { /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/ } @{$self->{genericsql}})) == 
          scalar(@{$self->{genericsql}}))) {
        $self->add_nagios_unknown(sprintf "got no valid response for %s",
            $params{selectname});
      } else {
        # name2 in array
        # units in array
      }
    }
  } elsif ($params{mode} =~ /^server::uptime/) {
    # already set with the connection. but use minutes here
  } elsif ($params{mode} =~ /^server::connectiontime/) {
    $self->{connection_time} = $self->{tac} - $self->{tic};
  } elsif ($params{mode} =~ /^my::([^:.]+)/) {
    my $class = $1;
    my $loaderror = undef;
    substr($class, 0, 1) = uc substr($class, 0, 1);
    foreach my $libpath (split(":", $DBD::MySQL::Server::my_modules_dyn_dir)) {
      foreach my $extmod (glob $libpath."/CheckMySQLHealth*.pm") {
        eval {
          $self->trace(sprintf "loading module %s", $extmod);
          require $extmod;
        };
        if ($@) {
          $loaderror = $extmod;
          $self->trace(sprintf "failed loading module %s: %s", $extmod, $@);
        }
      }
    }
    my $obj = {
        handle => $params{handle},
        warningrange => $params{warningrange},
        criticalrange => $params{criticalrange},
    };
    bless $obj, "My$class";
    $self->{my} = $obj;
    if ($self->{my}->isa("DBD::MySQL::Server")) {
      my $dos_init = $self->can("init");
      my $dos_nagios = $self->can("nagios");
      my $my_init = $self->{my}->can("init");
      my $my_nagios = $self->{my}->can("nagios");
      if ($my_init == $dos_init) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs an init() method", ref($self->{my}));
      } elsif ($my_nagios == $dos_nagios) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs a nagios() method", ref($self->{my}));
      } else {
        $self->{my}->init_nagios(%params);
        $self->{my}->init(%params);
      }
    } else {
      $self->add_nagios_unknown(
          sprintf "Class %s is not a subclass of DBD::MySQL::Server%s", 
              ref($self->{my}),
              $loaderror ? sprintf " (syntax error in %s?)", $loaderror : "" );
    }
  } else {
    printf "broken mode %s\n", $params{mode};
  }
}

sub dump {
  my $self = shift;
  my $message = shift || "";
  printf "%s %s\n", $message, Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /^server::instance/) {
      $self->{instance}->nagios(%params);
      $self->merge_nagios($self->{instance});
    } elsif ($params{mode} =~ /^server::database/) {
      $self->{database}->nagios(%params);
      $self->merge_nagios($self->{database});
    } elsif ($params{mode} =~ /^server::uptime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{uptime} / 60, "10:", "5:"),
          sprintf "database is up since %d minutes", $self->{uptime} / 60);
      $self->add_perfdata(sprintf "uptime=%ds",
          $self->{uptime});
    } elsif ($params{mode} =~ /^server::connectiontime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connection_time}, 1, 5),
          sprintf "%.2f seconds to connect as %s",
              $self->{connection_time}, ($self->{username} || getpwuid($<)));
      $self->add_perfdata(sprintf "connection_time=%.4fs;%d;%d",
          $self->{connection_time},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sql/) {
      if ($params{regexp}) {
        if (substr($params{name2}, 0, 1) eq '!') {
          $params{name2} =~ s/^!//;
          if ($self->{genericsql} !~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2});
          } else {
            $self->add_nagios_critical(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        } else {
          if ($self->{genericsql} =~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          } else {
            $self->add_nagios_critical(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        }
      } else {
        $self->add_nagios(
            # the first item in the list will trigger the threshold values
            $self->check_thresholds($self->{genericsql}[0], 1, 5),
                sprintf "%s: %s%s",
                $params{name2} ? lc $params{name2} : lc $params{selectname},
                # float as float, integers as integers
                join(" ", map {
                    (sprintf("%d", $_) eq $_) ? $_ : sprintf("%f", $_)
                } @{$self->{genericsql}}),
                $params{units} ? $params{units} : "");
        my $i = 0;
        # workaround... getting the column names from the database would be nicer
        my @names2_arr = split(/\s+/, $params{name2});
        foreach my $t (@{$self->{genericsql}}) {
          $self->add_perfdata(sprintf "\'%s\'=%s%s;%s;%s",
              $names2_arr[$i] ? lc $names2_arr[$i] : lc $params{selectname},
              # float as float, integers as integers
              (sprintf("%d", $t) eq $t) ? $t : sprintf("%f", $t),
              $params{units} ? $params{units} : "",
            ($i == 0) ? $self->{warningrange} : "",
              ($i == 0) ? $self->{criticalrange} : ""
          );
          $i++;
        }
      }
    } elsif ($params{mode} =~ /^my::([^:.]+)/) {
      $self->{my}->nagios(%params);
      $self->merge_nagios($self->{my});
    }
  }
}


sub init_nagios {
  my $self = shift;
  no strict 'refs';
  if (! ref($self)) {
    my $nagiosvar = $self."::nagios";
    my $nagioslevelvar = $self."::nagios_level";
    $$nagiosvar = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $$nagioslevelvar = $ERRORS{OK},
  } else {
    $self->{nagios} = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $self->{nagios_level} = $ERRORS{OK},
  }
}

sub check_thresholds {
  my $self = shift;
  my $value = shift;
  my $defaultwarningrange = shift;
  my $defaultcriticalrange = shift;
  my $level = $ERRORS{OK};
  $self->{warningrange} = defined $self->{warningrange} ?
      $self->{warningrange} : $defaultwarningrange;
  $self->{criticalrange} = defined $self->{criticalrange} ?
      $self->{criticalrange} : $defaultcriticalrange;
  if ($self->{warningrange} !~ /:/ && $self->{criticalrange} !~ /:/) {
    # warning = 10, critical = 20, warn if > 10, crit if > 20
    $level = $ERRORS{WARNING} if $value > $self->{warningrange};
    $level = $ERRORS{CRITICAL} if $value > $self->{criticalrange};
  } elsif ($self->{warningrange} =~ /([\d\.]+):/ && 
      $self->{criticalrange} =~ /([\d\.]+):/) {
    # warning = 98:, critical = 95:, warn if < 98, crit if < 95
    $self->{warningrange} =~ /([\d\.]+):/;
    $level = $ERRORS{WARNING} if $value < $1;
    $self->{criticalrange} =~ /([\d\.]+):/;
    $level = $ERRORS{CRITICAL} if $value < $1;
  }
  return $level;
  #
  # syntax error must be reported with returncode -1
  #
}

sub add_nagios {
  my $self = shift;
  my $level = shift;
  my $message = shift;
  push(@{$self->{nagios}->{messages}->{$level}}, $message);
  # recalc current level
  foreach my $llevel (qw(CRITICAL WARNING UNKNOWN OK)) {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$llevel}}})) {
      $self->{nagios_level} = $ERRORS{$llevel};
    }
  }
}

sub add_nagios_ok {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{OK}, $message);
}

sub add_nagios_warning {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{WARNING}, $message);
}

sub add_nagios_critical {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{CRITICAL}, $message);
}

sub add_nagios_unknown {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{UNKNOWN}, $message);
}

sub add_perfdata {
  my $self = shift;
  my $data = shift;
  push(@{$self->{nagios}->{perfdata}}, $data);
}

sub merge_nagios {
  my $self = shift;
  my $child = shift;
  foreach my $level (0..3) {
    foreach (@{$child->{nagios}->{messages}->{$level}}) {
      $self->add_nagios($level, $_);
    }
    #push(@{$self->{nagios}->{messages}->{$level}},
    #    @{$child->{nagios}->{messages}->{$level}});
  }
  push(@{$self->{nagios}->{perfdata}}, @{$child->{nagios}->{perfdata}});
}

sub calculate_result {
  my $self = shift;
  my $labels = shift || {};
  my $multiline = 0;
  map {
    $self->{nagios_level} = $ERRORS{$_} if
        (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}}));
  } ("OK", "UNKNOWN", "WARNING", "CRITICAL");
  if ($ENV{NRPE_MULTILINESUPPORT} &&
      length join(" ", @{$self->{nagios}->{perfdata}}) > 200) {
    $multiline = 1;
  }
  my $all_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN", "OK"));
  my $bad_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN"));
  my $all_messages_short = $bad_messages ? $bad_messages : 'no problems';
  my $all_messages_html = "<table style=\"border-collapse: collapse;\">".
      join("", map {
          my $level = $_;
          join("", map {
              sprintf "<tr valign=\"top\"><td class=\"service%s\">%s</td></tr>",
              $level, $_;
          } @{$self->{nagios}->{messages}->{$ERRORS{$_}}});
      } grep {
          scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
      } ("CRITICAL", "WARNING", "UNKNOWN", "OK")).
  "</table>";
  if (exists $self->{identstring}) {
    $self->{nagios_message} .= $self->{identstring};
  }
  if ($self->{report} eq "long") {
    $self->{nagios_message} .= $all_messages;
  } elsif ($self->{report} eq "short") {
    $self->{nagios_message} .= $all_messages_short;
  } elsif ($self->{report} eq "html") {
    $self->{nagios_message} .= $all_messages_short."\n".$all_messages_html;
  }
  if ($self->{labelformat} eq "pnp4nagios") {
    $self->{perfdata} = join(" ", @{$self->{nagios}->{perfdata}});
  } else {
    $self->{perfdata} = join(" ", map {
        my $perfdata = $_;
        if ($perfdata =~ /^(.*?)=(.*)/) {
          my $label = $1;
          my $data = $2;
          if (exists $labels->{$label} &&
              exists $labels->{$label}->{$self->{labelformat}}) {
            $labels->{$label}->{$self->{labelformat}}."=".$data;
          } else {
            $perfdata;
          }
        } else {
          $perfdata;
        }
    } @{$self->{nagios}->{perfdata}});
  }
}

sub set_global_db_thresholds {
  my $self = shift;
  my $params = shift;
  my $warning = undef;
  my $critical = undef;
  return unless defined $params->{dbthresholds};
  $params->{name0} = $params->{dbthresholds};
  # :pluginmode   :name     :warning    :critical
  # mode          empty     
  # 
  eval {
    if ($self->{handle}->fetchrow_array(q{
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = ?
        AND table_name = 'CHECK_MYSQL_HEALTH_THRESHOLDS';
      }, $self->{database})) { # either --database... or information_schema
      my @dbthresholds = $self->{handle}->fetchall_array(q{
          SELECT * FROM check_mysql_health_thresholds
      });
      $params->{dbthresholds} = \@dbthresholds;
      foreach (@dbthresholds) { 
        if (($_->[0] eq $params->{cmdlinemode}) &&
            (! defined $_->[1] || ! $_->[1])) {
          ($warning, $critical) = ($_->[2], $_->[3]);
        }
      }
    }
  };
  if (! $@) {
    if ($warning) {
      $params->{warningrange} = $warning;
      $self->trace("read warningthreshold %s from database", $warning);
    }
    if ($critical) {
      $params->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s from database", $critical);
    }
  }
}

sub set_local_db_thresholds {
  my $self = shift;
  my %params = @_;
  my $warning = undef;
  my $critical = undef;
  # :pluginmode   :name     :warning    :critical
  # mode          name0
  # mode          name2
  # mode          name
  #
  # first: argument of --dbthresholds, it it exists
  # second: --name2
  # third: --name
  if (ref($params{dbthresholds}) eq 'ARRAY') {
    my $marker;
    foreach (@{$params{dbthresholds}}) {
      if ($_->[0] eq $params{cmdlinemode}) {
        if (defined $_->[1] && $params{name0} && $_->[1] eq $params{name0}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name0};
          last;
        } elsif (defined $_->[1] && $params{name2} && $_->[1] eq $params{name2}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name2};
          last;
        } elsif (defined $_->[1] && $params{name} && $_->[1] eq $params{name}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name};
          last;
        }
      }
    }
    if ($warning) {
      $self->{warningrange} = $warning;
      $self->trace("read warningthreshold %s for %s from database",
         $marker, $warning);
    }
    if ($critical) {
      $self->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s for %s from database",
          $marker, $critical);
    }
  }
}

sub debug {
  my $self = shift;
  my $msg = shift;
  if ($DBD::MySQL::Server::verbose) {
    printf "%s %s\n", $msg, ref($self);
  }
}

sub dbconnect {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{tic} = Time::HiRes::time();
  $self->{handle} = DBD::MySQL::Server::Connection->new(%params);
  if ($self->{handle}->{errstr}) {
    if ($params{mode} =~ /^server::tnsping/ &&
        $self->{handle}->{errstr} =~ /ORA-01017/) {
      $self->add_nagios($ERRORS{OK},
          sprintf "connection established to %s.", $self->{connect});
      $retval = undef;
    } elsif ($self->{handle}->{errstr} eq "alarm\n") {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "connection could not be established within %d seconds",
              $self->{timeout});
    } else {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "cannot connect to %s. %s",
          $self->{database}, $self->{handle}->{errstr});
      $retval = undef;
    }
  } else {
    $retval = $self->{handle};
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub trace {
  my $self = shift;
  my $format = shift;
  $self->{trace} = -f "/tmp/check_mysql_health.trace" ? 1 : 0;
  if ($self->{verbose}) {
    printf("%s: ", scalar localtime);
    printf($format, @_);
  }
  if ($self->{trace}) {
    my $logfh = new IO::File;
    $logfh->autoflush(1);
    if ($logfh->open("/tmp/check_mysql_health.trace", "a")) {
      $logfh->printf("%s: ", scalar localtime);
      $logfh->printf($format, @_);
      $logfh->printf("\n");
      $logfh->close();
    }
  }
}

sub DESTROY {
  my $self = shift;
  my $handle1 = "null";
  my $handle2 = "null";
  if (defined $self->{handle}) {
    $handle1 = ref($self->{handle});
    if (defined $self->{handle}->{handle}) {
      $handle2 = ref($self->{handle}->{handle});
    }
  }
  $self->trace(sprintf "DESTROY %s with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MySQL::Server") {
  }
  $self->trace(sprintf "DESTROY %s exit with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MySQL::Server") {
    #printf "humpftata\n";
  }
}

sub save_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  }
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  if (! -d $params{statefilesdir}) {
    eval {
      use File::Path;
      mkpath $params{statefilesdir};
    };
  }
  if ($@ || ! -w $params{statefilesdir}) {
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefilesdir %s does not exist or is not writable\n",
        $params{statefilesdir});
    return;
  }
  my $statefile = sprintf "%s_%s", $params{hostname}, $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{socket} ? "_".$params{socket} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if (open(STATE, ">$statefile")) {
    if ((ref($params{save}) eq "HASH") && exists $params{save}->{timestamp}) {
      $params{save}->{localtime} = scalar localtime $params{save}->{timestamp};
    }
    printf STATE Data::Dumper::Dumper($params{save});
    close STATE;
  } else { 
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefile %s is not writable", $statefile);
  }
  $self->debug(sprintf "saved %s to %s",
      Data::Dumper::Dumper($params{save}), $statefile);
}

sub load_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  }
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  my $statefile = sprintf "%s_%s", $params{hostname}, $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{socket} ? "_".$params{socket} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if ( -f $statefile && -s $statefile) {
    our $VAR1;
    eval {
      require $statefile;
    } or do {
+      # Test again because of NFS mount...
+      require $statefile;
    };
    if($@) {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "statefile %s is corrupt", $statefile);
    }
    $self->debug(sprintf "load %s", Data::Dumper::Dumper($VAR1));
    return $VAR1;
  } else {
    return undef;
  }
}

sub valdiff {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my @keys = @_;
  my $now = time;
  my $last_values = $self->load_state(%params) || eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = 0;
    }
    $empty_events->{timestamp} = 0;
    if ($params{lookback}) {
      $empty_events->{lookback_history} = {};
    }
    $empty_events;
  };
  foreach (@keys) {
    if ($params{lookback}) {
      # find a last_value in the history which fits lookback best
      # and overwrite $last_values->{$_} with historic data
      if (exists $last_values->{lookback_history}->{$_}) {
        foreach my $date (sort {$a <=> $b} keys %{$last_values->{lookback_history}->{$_}}) {
          if ($date >= ($now - $params{lookback})) {
            $last_values->{$_} = $last_values->{lookback_history}->{$_}->{$date};
            $last_values->{timestamp} = $date;
            last;
          } else {
            delete $last_values->{lookback_history}->{$_}->{$date};
          }
        }
      }
    }
    $last_values->{$_} = 0 if ! exists $last_values->{$_};
    if ($self->{$_} >= $last_values->{$_}) {
      $self->{'delta_'.$_} = $self->{$_} - $last_values->{$_};
    } else {
      # vermutlich db restart und zaehler alle auf null
      $self->{'delta_'.$_} = $self->{$_};
    }
    $self->debug(sprintf "delta_%s %f", $_, $self->{'delta_'.$_});
  }
  $self->{'delta_timestamp'} = $now - $last_values->{timestamp};
  $params{save} = eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = $self->{$_};
    }
    $empty_events->{timestamp} = $now;
    if ($params{lookback}) {
      $empty_events->{lookback_history} = $last_values->{lookback_history};
      foreach (@keys) {
        $empty_events->{lookback_history}->{$_}->{$now} = $self->{$_};
      }
    }
    $empty_events;
  };
  $self->save_state(%params);
}

sub requires_version {
  my $self = shift;
  my $version = shift;
  my @instances = DBD::MySQL::Server::return_servers();
  my $instversion = $instances[0]->{version};
  if (! $self->version_is_minimum($version)) {
    $self->add_nagios($ERRORS{UNKNOWN}, 
        sprintf "not implemented/possible for MySQL release %s", $instversion);
  }
}

sub version_is_minimum {
  # the current version is newer or equal
  my $self = shift;
  my $version = shift;
  my $newer = 1;
  my @instances = DBD::MySQL::Server::return_servers();
  my @v1 = map { $_ eq "x" ? 0 : $_ } split(/\./, $version);
  my @v2 = split(/\./, $instances[0]->{version});
  if (scalar(@v1) > scalar(@v2)) {
    push(@v2, (0) x (scalar(@v1) - scalar(@v2)));
  } elsif (scalar(@v2) > scalar(@v1)) {
    push(@v1, (0) x (scalar(@v2) - scalar(@v1)));
  }
  foreach my $pos (0..$#v1) {
    if ($v2[$pos] > $v1[$pos]) {
      $newer = 1;
      last;
    } elsif ($v2[$pos] < $v1[$pos]) {
      $newer = 0;
      last;
    }
  }
  #printf STDERR "check if %s os minimum %s\n", join(".", @v2), join(".", @v1);
  return $newer;
}

sub instance_thread {
  my $self = shift;
  my @instances = DBD::MySQL::Server::return_servers();
  return $instances[0]->{thread};
}

sub windows_server {
  my $self = shift;
  my @instances = DBD::MySQL::Server::return_servers();
  if ($instances[0]->{os} =~ /Win/i) {
    return 1;
  } else {
    return 0;
  }
}

sub system_vartmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $self->system_tmpdir();
  } else {
    return '/var/tmp/plugin/'.$ENV{'NAGIOSENV'}.'/check_mssql_health';
  }
}

sub system_oldvartmpdir {
  my $self = shift;
  return "/tmp";
}

sub system_tmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $ENV{TEMP} if defined $ENV{TEMP};
    return $ENV{TMP} if defined $ENV{TMP};
    return File::Spec->catfile($ENV{windir}, 'Temp')
        if defined $ENV{windir};
    return 'C:\Temp';
  } else {
    return "/tmp";
  }
}


package DBD::MySQL::Server::Connection;

use strict;

our @ISA = qw(DBD::MySQL::Server);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    timeout => $params{timeout},
    access => $params{method} || "dbi",
    hostname => $params{hostname},
    database => $params{database} || "information_schema",
    port => $params{port},
    socket => $params{socket},
    username => $params{username},
    password => $params{password},
    mycnf => $params{mycnf},
    mycnfgroup => $params{mycnfgroup},
    handle => undef,
  };
  bless $self, $class;
  if ($params{method} eq "dbi") {
    bless $self, "DBD::MySQL::Server::Connection::Dbi";
  } elsif ($params{method} eq "mysql") {
    bless $self, "DBD::MySQL::Server::Connection::Mysql";
  } elsif ($params{method} eq "sqlrelay") {
    bless $self, "DBD::MySQL::Server::Connection::Sqlrelay";
  }
  $self->init(%params);
  return $self;
}


package DBD::MySQL::Server::Connection::Dbi;

use strict;
use Net::Ping;

our @ISA = qw(DBD::MySQL::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{username} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    if (
        ($self->{hostname} ne 'localhost' && (! $self->{username} || ! $self->{password})) && 
        (! $self->{mycnf}) ) {
      $self->{errstr} = "Please specify hostname, username and password or a .cnf file";
      return undef;
    }
    $self->{dsn} = "DBI:mysql:";
    $self->{dsn} .= sprintf "database=%s", $self->{database};
    if ($self->{mycnf}) {
      $self->{dsn} .= sprintf ";mysql_read_default_file=%s", $self->{mycnf};
      if ($self->{mycnfgroup}) {
        $self->{dsn} .= sprintf ";mysql_read_default_group=%s", $self->{mycnfgroup};
      }
    } else {
      $self->{dsn} .= sprintf ";host=%s", $self->{hostname};
      $self->{dsn} .= sprintf ";port=%s", $self->{port}
          unless $self->{socket} || $self->{hostname} eq 'localhost';
      $self->{dsn} .= sprintf ";mysql_socket=%s", $self->{socket} 
          if $self->{socket};
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      if ($self->{handle} = DBI->connect(
          $self->{dsn},
          $self->{username},
          $self->{password},
          { RaiseError => 0, AutoCommit => 0, PrintError => 0 })) {
#        $self->{handle}->do(q{
#            ALTER SESSION SET NLS_NUMERIC_CHARACTERS=".," });
        $retval = $self;
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub selectrow_hashref {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $hashref = undef;
  eval {
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    # helm auf! jetzt wirds dreckig.
    if ($sql =~ /^\s*SHOW/) {
      $hashref = $self->{handle}->selectrow_hashref($sql);
    } else {
      $sth = $self->{handle}->prepare($sql);
      if (scalar(@arguments)) {
        $sth->execute(@arguments);
      } else {
        $sth->execute();
      }
      $hashref = $sth->selectrow_hashref();
    }
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($hashref));
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_mysql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_mysql_health_simulation/".$self->{mode}; <> };
    # keine lust auf den scheiss
  }
  return $hashref;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  eval {
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }; 
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_mysql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_mysql_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  eval {
    $self->trace(sprintf "SQL:\n%s\nARGS:\n%s\n",
        $sql, Data::Dumper::Dumper(\@arguments));
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }; 
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_mysql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_mysql_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub errstr {
  my $self = shift;
  return $self->{errstr};
}

sub DESTROY {
  my $self = shift;
  $self->trace(sprintf "disconnecting DBD %s",
      $self->{handle} ? "with handle" : "without handle");
  $self->{handle}->disconnect() if $self->{handle};
}

package DBD::MySQL::Server::Connection::Mysql;

use strict;
use File::Temp qw/tempfile/;

our @ISA = qw(DBD::MySQL::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{loginstring} = "traditional";
  ($self->{sql_commandfile_handle}, $self->{sql_commandfile}) =
      tempfile($self->{mode}."XXXXX", SUFFIX => ".sql", 
      DIR => $self->system_tmpdir() );
  close $self->{sql_commandfile_handle};
  ($self->{sql_resultfile_handle}, $self->{sql_resultfile}) =
      tempfile($self->{mode}."XXXXX", SUFFIX => ".out", 
      DIR => $self->system_tmpdir() );
  close $self->{sql_resultfile_handle};
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{username} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    if (! $self->{username} || ! $self->{password}) {
      $self->{errstr} = "Please specify database, username and password";
      return undef;
    } elsif (! (($self->{hostname} && $self->{port}) || $self->{socket})) {
      $self->{errstr} = "Please specify hostname and port or socket";
      return undef;
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      my $mysql = '/'.'usr'.'/'.'bin'.'/'.'mysql';
      if (! -x $mysql) {
        die "nomysql\n";
      }
      if ($self->{loginstring} eq "traditional") {
        $self->{sqlplus} = sprintf "%s ", $mysql;
        $self->{sqlplus} .= sprintf "--batch --raw --skip-column-names ";
        $self->{sqlplus} .= sprintf "--database=%s ", $self->{database};
        $self->{sqlplus} .= sprintf "--host=%s ", $self->{hostname};
        $self->{sqlplus} .= sprintf "--port=%s ", $self->{port}
            unless $self->{socket} || $self->{hostname} eq "localhost";
        $self->{sqlplus} .= sprintf "--socket=%s ", $self->{socket}
            if $self->{socket};
        $self->{sqlplus} .= sprintf "--user=%s --password=%s < %s > %s",
            $self->{username}, $self->{password},
            $self->{sql_commandfile}, $self->{sql_resultfile};
      }
  
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
  
      my $answer = $self->fetchrow_array(
          q{ SELECT 42 FROM dual});
      die unless defined $answer and $answer == 42;
      $retval = $self;
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at $0 .*//g;
      chomp $self->{errstr};
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub selectrow_hashref {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $hashref = undef;
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  if ($sql =~ /^\s*SHOW/) {
    $sql .= '\G'; # http://dev.mysql.com/doc/refman/5.1/de/show-slave-status.html
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlplus}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm \n";
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /((ERROR \d+).*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    if ($sql =~ /^\s*SHOW/) {
      map {
        if (/^\s*([\w_]+):\s*(.*)/) {
          $hashref->{$1} = $2;
        }
      } split(/\n/, $output);
    } else {
      # i dont mess around here and you shouldn't either
    }
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($hashref));
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return $hashref;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlplus}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm \n";
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /((ERROR \d+).*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    @row = map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\t/, (split(/\n/, $output))[0]);
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->trace(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->create_commandfile($sql);
  my $exit_output = `$self->{sqlplus}`;
  if ($?) {
    printf STDERR "fetchrow_array exit bumm %s\n", $exit_output;
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @oerrs = map {
      /((ERROR \d+).*)/ ? $1 : ();
    } split(/\n/, $output);
    $self->{errstr} = join(" ", @oerrs);
  } else {
    my $output = do { local (@ARGV, $/) = $self->{sql_resultfile}; <> };
    my @rows = map { [ 
        map { convert($_) } 
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\t/
    ] } grep { ! /^\d+ rows selected/ } 
        grep { ! /^Elapsed: / }
        grep { ! /^\s*$/ } split(/\n/, $output);
    $rows = \@rows;
    $self->trace(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  unlink $self->{sql_commandfile};
  unlink $self->{sql_resultfile};
  return @{$rows};
}

sub func {
  my $self = shift;
  my $function = shift;
  $self->{handle}->func(@_);
}

sub convert {
  my $n = shift;
  # mostly used to convert numbers in scientific notation
  if ($n =~ /^\s*\d+\s*$/) {
    return $n;
  } elsif ($n =~ /^\s*([-+]?)(\d*[\.,]*\d*)[eE]{1}([-+]?)(\d+)\s*$/) {
    my ($vor, $num, $sign, $exp) = ($1, $2, $3, $4);
    $n =~ s/E/e/g;
    $n =~ s/,/\./g;
    $num =~ s/,/\./g;
    my $sig = $sign eq '-' ? "." . ($exp - 1 + length $num) : '';
    my $dec = sprintf "%${sig}f", $n;
    $dec =~ s/\.[0]+$//g;
    return $dec;
  } elsif ($n =~ /^\s*([-+]?)(\d+)[\.,]*(\d*)\s*$/) {
    return $1.$2.".".$3;
  } elsif ($n =~ /^\s*(.*?)\s*$/) {
    return $1;
  } else {
    return $n;
  }
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub errstr {
  my $self = shift;
  return $self->{errstr};
}

sub DESTROY {
  my $self = shift;
  $self->trace("try to clean up command and result files");
  unlink $self->{sql_commandfile} if -f $self->{sql_commandfile};
  unlink $self->{sql_resultfile} if -f $self->{sql_resultfile};
}

sub create_commandfile {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $self->{sql_commandfile}"; 
  printf CMDCMD "%s\n", $sql;
  close CMDCMD;
}


package DBD::MySQL::Server::Connection::Sqlrelay;

use strict;
use Net::Ping;

our @ISA = qw(DBD::MySQL::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      if ($self->{connect} =~ /([\.\w]+):(\d+)/) {
        $self->{host} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{connect} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{host} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      }
    }
  } else {
    if (! $self->{hostname} || ! $self->{username} || ! $self->{password}) {
      if ($self->{hostname} && $self->{hostname} =~ /(\w+)\/(\w+)@([\.\w]+):(\d+)/) {
        $self->{username} = $1;
        $self->{password} = $2;
        $self->{hostname} = $3;
        $self->{port} = $4;
        $self->{socket} = "";
      } elsif ($self->{hostname} && $self->{hostname} =~ /(\w+)\/(\w+)@([\.\w]+):([\w\/]+)/) {
        $self->{username} = $1;
        $self->{password} = $2;
        $self->{hostname} = $3;
        $self->{socket} = $4;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    } else {
      if ($self->{hostname} =~ /([\.\w]+):(\d+)/) {
        $self->{hostname} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{hostname} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{hostname} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify hostname, username, password and port/socket";
        return undef;
      }
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      if ($self->{handle} = DBI->connect(
          sprintf("DBI:SQLRelay:host=%s;port=%d;socket=%s", 
          $self->{hostname}, $self->{port}, $self->{socket}),
          $self->{username},
          $self->{password},
          { RaiseError => 1, AutoCommit => 0, PrintError => 1 })) {
        $retval = $self;
        if ($self->{mode} =~ /^server::tnsping/ && $self->{handle}->ping()) {
          # database connected. fake a "unknown user"
          $self->{errstr} = "ORA-01017";
        }
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at [\w\/\.]+ line \d+.*//g;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  $self->trace(sprintf "fetchrow_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_mysql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_mysql_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  $self->trace(sprintf "fetchall_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_mysql_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_mysql_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}

sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  #$self->trace(sprintf "disconnecting DBD %s",
  #    $self->{handle} ? "with handle" : "without handle");
  #$self->{handle}->disconnect() if $self->{handle};
}




package DBD::MySQL::Cluster;

use strict;
use Time::HiRes;
use IO::File;
use Data::Dumper;


{
  our $verbose = 0;
  our $scream = 0; # scream if something is not implemented
  our $access = "dbi"; # how do we access the database. 
  our $my_modules_dyn_dir = ""; # where we look for self-written extensions

  my @clusters = ();
  my $initerrors = undef;

  sub add_cluster {
    push(@clusters, shift);
  }

  sub return_clusters {
    return @clusters;
  }
  
  sub return_first_cluster() {
    return $clusters[0];
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    hostname => $params{hostname},
    port => $params{port},
    username => $params{username},
    password => $params{password},
    timeout => $params{timeout},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    version => 'unknown',
    nodes => [],
    ndbd_nodes => 0,
    ndb_mgmd_nodes => 0,
    mysqld_nodes => 0,
  };
  bless $self, $class;
  $self->init_nagios();
  if ($self->connect(%params)) {
    DBD::MySQL::Cluster::add_cluster($self);
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  if ($self->{show}) {
    my $type = undef;
    foreach (split /\n/, $self->{show}) {
      if (/\[(\w+)\((\w+)\)\]\s+(\d+) node/) {
        $type = uc $2;
      } elsif (/id=(\d+)(.*)/) {
        push(@{$self->{nodes}}, DBD::MySQL::Cluster::Node->new(
            type => $type,
            id => $1,
            status => $2,
        ));
      }
    }
  } else {
  }
  if ($params{mode} =~ /^cluster::ndbdrunning/) {
    foreach my $node (@{$self->{nodes}}) {
      $node->{type} eq "NDB" && $node->{status} eq "running" && $self->{ndbd_nodes}++;
      $node->{type} eq "MGM" && $node->{status} eq "running" && $self->{ndb_mgmd_nodes}++;
      $node->{type} eq "API" && $node->{status} eq "running" && $self->{mysqld_nodes}++;
    }
  } else {
    printf "broken mode %s\n", $params{mode};
  }
}

sub dump {
  my $self = shift;
  my $message = shift || "";
  printf "%s %s\n", $message, Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
  my %params = @_;
  my $dead_ndb = 0;
  my $dead_api = 0;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /^cluster::ndbdrunning/) {
      foreach my $node (grep { $_->{type} eq "NDB"} @{$self->{nodes}}) {
        next if $params{selectname} && $params{selectname} ne $_->{id};
        if (! $node->{connected}) {
          $self->add_nagios_critical(
              sprintf "ndb node %d is not connected", $node->{id});
          $dead_ndb++;
        }
      }
      foreach my $node (grep { $_->{type} eq "API"} @{$self->{nodes}}) {
        next if $params{selectname} && $params{selectname} ne $_->{id};
        if (! $node->{connected}) {
          $self->add_nagios_critical(
              sprintf "api node %d is not connected", $node->{id});
          $dead_api++;
        }
      }
      if (! $dead_ndb) {
        $self->add_nagios_ok("all ndb nodes are connected");
      }
      if (! $dead_api) {
        $self->add_nagios_ok("all api nodes are connected");
      }
    }
  }
  $self->add_perfdata(sprintf "ndbd_nodes=%d ndb_mgmd_nodes=%d mysqld_nodes=%d",
      $self->{ndbd_nodes}, $self->{ndb_mgmd_nodes}, $self->{mysqld_nodes});
}


sub init_nagios {
  my $self = shift;
  no strict 'refs';
  if (! ref($self)) {
    my $nagiosvar = $self."::nagios";
    my $nagioslevelvar = $self."::nagios_level";
    $$nagiosvar = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $$nagioslevelvar = $ERRORS{OK},
  } else {
    $self->{nagios} = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $self->{nagios_level} = $ERRORS{OK},
  }
}

sub check_thresholds {
  my $self = shift;
  my $value = shift;
  my $defaultwarningrange = shift;
  my $defaultcriticalrange = shift;
  my $level = $ERRORS{OK};
  $self->{warningrange} = $self->{warningrange} ?
      $self->{warningrange} : $defaultwarningrange;
  $self->{criticalrange} = $self->{criticalrange} ?
      $self->{criticalrange} : $defaultcriticalrange;
  if ($self->{warningrange} !~ /:/ && $self->{criticalrange} !~ /:/) {
    # warning = 10, critical = 20, warn if > 10, crit if > 20
    $level = $ERRORS{WARNING} if $value > $self->{warningrange};
    $level = $ERRORS{CRITICAL} if $value > $self->{criticalrange};
  } elsif ($self->{warningrange} =~ /([\d\.]+):/ && 
      $self->{criticalrange} =~ /([\d\.]+):/) {
    # warning = 98:, critical = 95:, warn if < 98, crit if < 95
    $self->{warningrange} =~ /([\d\.]+):/;
    $level = $ERRORS{WARNING} if $value < $1;
    $self->{criticalrange} =~ /([\d\.]+):/;
    $level = $ERRORS{CRITICAL} if $value < $1;
  }
  return $level;
  #
  # syntax error must be reported with returncode -1
  #
}

sub add_nagios {
  my $self = shift;
  my $level = shift;
  my $message = shift;
  push(@{$self->{nagios}->{messages}->{$level}}, $message);
  # recalc current level
  foreach my $llevel (qw(CRITICAL WARNING UNKNOWN OK)) {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$llevel}}})) {
      $self->{nagios_level} = $ERRORS{$llevel};
    }
  }
}

sub add_nagios_ok {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{OK}, $message);
}

sub add_nagios_warning {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{WARNING}, $message);
}

sub add_nagios_critical {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{CRITICAL}, $message);
}

sub add_nagios_unknown {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{UNKNOWN}, $message);
}

sub add_perfdata {
  my $self = shift;
  my $data = shift;
  push(@{$self->{nagios}->{perfdata}}, $data);
}

sub merge_nagios {
  my $self = shift;
  my $child = shift;
  foreach my $level (0..3) {
    foreach (@{$child->{nagios}->{messages}->{$level}}) {
      $self->add_nagios($level, $_);
    }
    #push(@{$self->{nagios}->{messages}->{$level}},
    #    @{$child->{nagios}->{messages}->{$level}});
  }
  push(@{$self->{nagios}->{perfdata}}, @{$child->{nagios}->{perfdata}});
}


sub calculate_result {
  my $self = shift;
  if ($ENV{NRPE_MULTILINESUPPORT} && 
      length join(" ", @{$self->{nagios}->{perfdata}}) > 200) {
    foreach my $level ("CRITICAL", "WARNING", "UNKNOWN", "OK") {
      # first the bad news
      if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
        $self->{nagios_message} .=
            "\n".join("\n", @{$self->{nagios}->{messages}->{$ERRORS{$level}}});
      }
    }
    $self->{nagios_message} =~ s/^\n//g;
    $self->{perfdata} = join("\n", @{$self->{nagios}->{perfdata}});
  } else {
    foreach my $level ("CRITICAL", "WARNING", "UNKNOWN", "OK") {
      # first the bad news
      if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
        $self->{nagios_message} .= 
            join(", ", @{$self->{nagios}->{messages}->{$ERRORS{$level}}}).", ";
      }
    }
    $self->{nagios_message} =~ s/, $//g;
    $self->{perfdata} = join(" ", @{$self->{nagios}->{perfdata}});
  }
  foreach my $level ("OK", "UNKNOWN", "WARNING", "CRITICAL") {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$level}}})) {
      $self->{nagios_level} = $ERRORS{$level};
    }
  }
}

sub debug {
  my $self = shift;
  my $msg = shift;
  if ($DBD::MySQL::Cluster::verbose) {
    printf "%s %s\n", $msg, ref($self);
  }
}

sub connect {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{tic} = Time::HiRes::time();
  eval {
    use POSIX ':signal_h';
    local $SIG{'ALRM'} = sub {
      die "alarm\n";
    };
    my $mask = POSIX::SigSet->new( SIGALRM );
    my $action = POSIX::SigAction->new(
        sub { die "connection timeout\n" ; }, $mask);
    my $oldaction = POSIX::SigAction->new();
    sigaction(SIGALRM ,$action ,$oldaction );
    alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
    my $ndb_mgm = "ndb_mgm";
    $params{hostname} = "127.0.0.1" if ! $params{hostname};
    $ndb_mgm .= sprintf " --ndb-connectstring=%s", $params{hostname}
        if $params{hostname};
    $ndb_mgm .= sprintf ":%d", $params{port}
        if $params{port};
    $self->{show} = `$ndb_mgm -e show 2>&1`;
    if ($? == -1) {
      $self->add_nagios_critical("ndb_mgm failed to execute $!");
    } elsif ($? & 127) {
      $self->add_nagios_critical("ndb_mgm failed to execute $!");
    } elsif ($? >> 8 != 0) {
      $self->add_nagios_critical("ndb_mgm unable to connect");
    } else {
      if ($self->{show} !~ /Cluster Configuration/) {
        $self->add_nagios_critical("got no cluster configuration");
      } else {
        $retval = 1;
      }
    }
  };
  if ($@) {
    $self->{errstr} = $@;
    $self->{errstr} =~ s/at $0 .*//g;
    chomp $self->{errstr};
    $self->add_nagios_critical($self->{errstr});
    $retval = undef;
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub trace {
  my $self = shift;
  my $format = shift;
  $self->{trace} = -f "/tmp/check_mysql_health.trace" ? 1 : 0;
  if ($self->{verbose}) {
    printf("%s: ", scalar localtime);
    printf($format, @_);
  }
  if ($self->{trace}) {
    my $logfh = new IO::File;
    $logfh->autoflush(1);
    if ($logfh->open("/tmp/check_mysql_health.trace", "a")) {
      $logfh->printf("%s: ", scalar localtime);
      $logfh->printf($format, @_);
      $logfh->printf("\n");
      $logfh->close();
    }
  }
}

sub DESTROY {
  my $self = shift;
  my $handle1 = "null";
  my $handle2 = "null";
  if (defined $self->{handle}) {
    $handle1 = ref($self->{handle});
    if (defined $self->{handle}->{handle}) {
      $handle2 = ref($self->{handle}->{handle});
    }
  }
  $self->trace(sprintf "DESTROY %s with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MySQL::Cluster") {
  }
  $self->trace(sprintf "DESTROY %s exit with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::MySQL::Cluster") {
    #printf "humpftata\n";
  }
}

sub save_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  mkdir $params{statefilesdir} unless -d $params{statefilesdir};
  my $statefile = sprintf "%s/%s_%s", 
      $params{statefilesdir}, $params{hostname}, $params{mode};
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{socket} ? "_".$params{socket} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  open(STATE, ">$statefile");
  if ((ref($params{save}) eq "HASH") && exists $params{save}->{timestamp}) {
    $params{save}->{localtime} = scalar localtime $params{save}->{timestamp};
  }
  printf STATE Data::Dumper::Dumper($params{save});
  close STATE;
  $self->debug(sprintf "saved %s to %s",
      Data::Dumper::Dumper($params{save}), $statefile);
}

sub load_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $statefile = sprintf "%s/%s_%s", 
      $params{statefilesdir}, $params{hostname}, $params{mode};
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{socket} ? "_".$params{socket} : "";
  $extension .= $params{port} ? "_".$params{port} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  if ( -f $statefile) {
    our $VAR1;
    eval {
      require $statefile;
    };
    if($@) {
printf "rumms\n";
    }
    $self->debug(sprintf "load %s", Data::Dumper::Dumper($VAR1));
    return $VAR1;
  } else {
    return undef;
  }
}

sub valdiff {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my @keys = @_;
  my $last_values = $self->load_state(%params) || eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = 0;
    }
    $empty_events->{timestamp} = 0;
    $empty_events;
  };
  foreach (@keys) {
    $self->{'delta_'.$_} = $self->{$_} - $last_values->{$_};
    $self->debug(sprintf "delta_%s %f", $_, $self->{'delta_'.$_});
  }
  $self->{'delta_timestamp'} = time - $last_values->{timestamp};
  $params{save} = eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = $self->{$_};
    }
    $empty_events->{timestamp} = time;
    $empty_events;
  };
  $self->save_state(%params);
}

sub requires_version {
  my $self = shift;
  my $version = shift;
  my @instances = DBD::MySQL::Cluster::return_clusters();
  my $instversion = $instances[0]->{version};
  if (! $self->version_is_minimum($version)) {
    $self->add_nagios($ERRORS{UNKNOWN}, 
        sprintf "not implemented/possible for MySQL release %s", $instversion);
  }
}

sub version_is_minimum {
  # the current version is newer or equal
  my $self = shift;
  my $version = shift;
  my $newer = 1;
  my @instances = DBD::MySQL::Cluster::return_clusters();
  my @v1 = map { $_ eq "x" ? 0 : $_ } split(/\./, $version);
  my @v2 = split(/\./, $instances[0]->{version});
  if (scalar(@v1) > scalar(@v2)) {
    push(@v2, (0) x (scalar(@v1) - scalar(@v2)));
  } elsif (scalar(@v2) > scalar(@v1)) {
    push(@v1, (0) x (scalar(@v2) - scalar(@v1)));
  }
  foreach my $pos (0..$#v1) {
    if ($v2[$pos] > $v1[$pos]) {
      $newer = 1;
      last;
    } elsif ($v2[$pos] < $v1[$pos]) {
      $newer = 0;
      last;
    }
  }
  #printf STDERR "check if %s os minimum %s\n", join(".", @v2), join(".", @v1);
  return $newer;
}

sub instance_rac {
  my $self = shift;
  my @instances = DBD::MySQL::Cluster::return_clusters();
  return (lc $instances[0]->{parallel} eq "yes") ? 1 : 0;
}

sub instance_thread {
  my $self = shift;
  my @instances = DBD::MySQL::Cluster::return_clusters();
  return $instances[0]->{thread};
}

sub windows_cluster {
  my $self = shift;
  my @instances = DBD::MySQL::Cluster::return_clusters();
  if ($instances[0]->{os} =~ /Win/i) {
    return 1;
  } else {
    return 0;
  }
}

sub system_vartmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $self->system_tmpdir();
  } else {
    return "/var/tmp/check_mysql_health";
  }
}

sub system_oldvartmpdir {
  my $self = shift;
  return "/tmp";
}

sub system_tmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $ENV{TEMP} if defined $ENV{TEMP};
    return $ENV{TMP} if defined $ENV{TMP};
    return File::Spec->catfile($ENV{windir}, 'Temp')
        if defined $ENV{windir};
    return 'C:\Temp';
  } else {
    return "/tmp";
  }
}


package DBD::MySQL::Cluster::Node;

use strict;

our @ISA = qw(DBD::MySQL::Cluster);


sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    timeout => $params{timeout},
    type => $params{type},
    id => $params{id},
    status => $params{status},
  };
  bless $self, $class;
  $self->init(%params);
  if ($params{type} eq "NDB") {
    bless $self, "DBD::MySQL::Cluster::Node::NDB";
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  if ($self->{status} =~ /@(\d+\.\d+\.\d+\.\d+)\s/) {
    $self->{addr} = $1;
    $self->{connected} = 1;
  } elsif ($self->{status} =~ /accepting connect from (\d+\.\d+\.\d+\.\d+)/) {
    $self->{addr} = $1;
    $self->{connected} = 0;
  }
  if ($self->{status} =~ /starting,/) {
    $self->{status} = "starting";
  } elsif ($self->{status} =~ /shutting,/) {
    $self->{status} = "shutting";
  } else {
    $self->{status} = $self->{connected} ? "running" : "dead";
  }
}


package DBD::MySQL::Cluster::Node::NDB;

use strict;

our @ISA = qw(DBD::MySQL::Cluster::Node);


sub init {
  my $self = shift;
  my %params = @_;
  if ($self->{status} =~ /Nodegroup:\s*(\d+)/) {
    $self->{nodegroup} = $1;
  }
  $self->{master} = ($self->{status} =~ /Master\)/) ? 1 : 0;
}


package Extraopts;

use strict;
use File::Basename;
use Data::Dumper;

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    file => $params{file},
    commandline => $params{commandline},
    config => {},
    section => 'default_no_section',
  };
  bless $self, $class;
  $self->prepare_file_and_section();
  $self->init();
  return $self;
}

sub prepare_file_and_section {
  my $self = shift;
  if (! defined $self->{file}) {
    # ./check_stuff --extra-opts
    $self->{section} = basename($0);
    $self->{file} = $self->get_default_file();
  } elsif ($self->{file} =~ /^[^@]+$/) {
    # ./check_stuff --extra-opts=special_opts
    $self->{section} = $self->{file};
    $self->{file} = $self->get_default_file();
  } elsif ($self->{file} =~ /^@(.*)/) {
    # ./check_stuff --extra-opts=@/etc/myconfig.ini
    $self->{section} = basename($0);
    $self->{file} = $1;
  } elsif ($self->{file} =~ /^(.*?)@(.*)/) {
    # ./check_stuff --extra-opts=special_opts@/etc/myconfig.ini
    $self->{section} = $1;
    $self->{file} = $2;
  }
}

sub get_default_file {
  my $self = shift;
  foreach my $default (qw(/etc/nagios/plugins.ini
      /usr/local/nagios/etc/plugins.ini
      /usr/local/etc/nagios/plugins.ini
      /etc/opt/nagios/plugins.ini
      /etc/nagios-plugins.ini
      /usr/local/etc/nagios-plugins.ini
      /etc/opt/nagios-plugins.ini)) {
    if (-f $default) {
      return $default;
    }
  }
  return undef;
}

sub init {
  my $self = shift;
  if (! defined $self->{file}) {
    $self->{errors} = sprintf 'no extra-opts file specified and no default file found';
  } elsif (! -f $self->{file}) {
    $self->{errors} = sprintf 'could not open %s', $self->{file};
  } else {
    my $data = do { local (@ARGV, $/) = $self->{file}; <> };
    my $in_section = 'default_no_section';
    foreach my $line (split(/\n/, $data)) {
      if ($line =~ /\[(.*)\]/) {
        $in_section = $1;
      } elsif ($line =~ /(.*?)\s*=\s*(.*)/) {
        $self->{config}->{$in_section}->{$1} = $2;
      }
    }
  }
}

sub is_valid {
  my $self = shift;
  return ! exists $self->{errors};
}

sub overwrite {
  my $self = shift;
  my %commandline = ();
  if (scalar(keys %{$self->{config}->{default_no_section}}) > 0) {
    foreach (keys %{$self->{config}->{default_no_section}}) {
      $commandline{$_} = $self->{config}->{default_no_section}->{$_};
    }
  }
  if (exists $self->{config}->{$self->{section}}) {
    foreach (keys %{$self->{config}->{$self->{section}}}) {
      $commandline{$_} = $self->{config}->{$self->{section}}->{$_};
    }
  }
  foreach (keys %commandline) {
    if (! exists $self->{commandline}->{$_}) {
      $self->{commandline}->{$_} = $commandline{$_};
    }
  }
}



package main;

use strict;
use Getopt::Long qw(:config no_ignore_case);
use File::Basename;
use lib dirname($0);



use vars qw ($PROGNAME $REVISION $CONTACT $TIMEOUT $STATEFILESDIR $needs_restart %commandline);

$PROGNAME = "check_mysql_health";
$REVISION = '$Revision: 2.1.8.2 $';
$CONTACT = 'gerhard.lausser@consol.de';
$TIMEOUT = 60;
$STATEFILESDIR = '/var/tmp/plugin/'.$ENV{'NAGIOSENV'}.'/check_mssql_health';
$needs_restart = 0;

my @modes = (
  ['server::connectiontime',
      'connection-time', undef,
      'Time to connect to the server' ],
  ['server::uptime',
      'uptime', undef,
      'Time the server is running' ],
  ['server::instance::connectedthreads',
      'threads-connected', undef,
      'Number of currently open connections' ],
  ['server::instance::threadcachehitrate',
      'threadcache-hitrate', undef,
      'Hit rate of the thread-cache' ],
  ['server::instance::createdthreads',
      'threads-created', undef,
      'Number of threads created per sec' ],
  ['server::instance::runningthreads',
      'threads-running', undef,
      'Number of currently running threads' ],
  ['server::instance::cachedthreads',
      'threads-cached', undef,
      'Number of currently cached threads' ],
  ['server::instance::abortedconnects',
      'connects-aborted', undef,
      'Number of aborted connections per sec' ],
  ['server::instance::abortedclients',
      'clients-aborted', undef,
      'Number of aborted connections (because the client died) per sec' ],
  ['server::instance::replication::slavelag',
      'slave-lag', ['replication-slave-lag'],
      'Seconds behind master' ],
  ['server::instance::replication::slaveiorunning',
      'slave-io-running', ['replication-slave-io-running'],
      'Slave io running: Yes' ],
  ['server::instance::replication::slavesqlrunning',
      'slave-sql-running', ['replication-slave-sql-running'],
      'Slave sql running: Yes' ],
  ['server::instance::querycachehitrate',
      'qcache-hitrate', ['querycache-hitrate'],
      'Query cache hitrate' ],
  ['server::instance::querycachelowmemprunes',
      'qcache-lowmem-prunes', ['querycache-lowmem-prunes'],
      'Query cache entries pruned because of low memory' ],
  ['server::instance::myisam::keycache::hitrate',
      'keycache-hitrate', ['myisam-keycache-hitrate'],
      'MyISAM key cache hitrate' ],
  ['server::instance::innodb::bufferpool::hitrate',
      'bufferpool-hitrate', ['innodb-bufferpool-hitrate'],
      'InnoDB buffer pool hitrate' ],
  ['server::instance::innodb::bufferpool::waitfree',
      'bufferpool-wait-free', ['innodb-bufferpool-wait-free'],
      'InnoDB buffer pool waits for clean page available' ],
  ['server::instance::innodb::logwaits',
      'log-waits', ['innodb-log-waits'],
      'InnoDB log waits because of a too small log buffer' ],
  ['server::instance::tablecachehitrate',
      'tablecache-hitrate', undef,
      'Table cache hitrate' ],
  ['server::instance::tablelockcontention',
      'table-lock-contention', undef,
      'Table lock contention' ],
  ['server::instance::tableindexusage',
      'index-usage', undef,
      'Usage of indices' ],
  ['server::instance::tabletmpondisk',
      'tmp-disk-tables', undef,
      'Percent of temp tables created on disk' ],
  ['server::instance::needoptimize',
      'table-fragmentation', undef,
      'Show tables which should be optimized' ],
  ['server::instance::openfiles',
      'open-files', undef,
      'Percent of opened files' ],
  ['server::instance::slowqueries',
      'slow-queries', undef,
      'Slow queries' ],
  ['server::instance::longprocs',
      'long-running-procs', undef,
      'long running processes' ],
  ['cluster::ndbdrunning',
      'cluster-ndbd-running', undef,
      'ndnd nodes are up and running' ],
  ['server::sql',
      'sql', undef,
      'any sql command returning a single number' ],
);

# rrd data store names are limited to 19 characters
my %labels = (
  bufferpool_hitrate => {
    groundwork => 'bp_hitrate',
  },
  bufferpool_hitrate_now => {
    groundwork => 'bp_hitrate_now',
  },
  bufferpool_free_waits_rate => {
    groundwork => 'bp_freewaits',
  },
  innodb_log_waits_rate => {
    groundwork => 'inno_log_waits',
  },
  keycache_hitrate => {
    groundwork => 'kc_hitrate',
  },
  keycache_hitrate_now => {
    groundwork => 'kc_hitrate_now',
  },
  threads_created_per_sec => {
    groundwork => 'thrds_creat_per_s',
  },
  connects_aborted_per_sec => {
    groundwork => 'conn_abrt_per_s',
  },
  clients_aborted_per_sec => {
    groundwork => 'clnt_abrt_per_s',
  },
  thread_cache_hitrate => {
    groundwork => 'tc_hitrate',
  },
  thread_cache_hitrate_now => {
    groundwork => 'tc_hitrate_now',
  },
  qcache_lowmem_prunes_rate => {
    groundwork => 'qc_lowm_prnsrate',
  },
  slow_queries_rate => {
    groundwork => 'slow_q_rate',
  },
  tablecache_hitrate => {
    groundwork => 'tac_hitrate',
  },
  tablecache_fillrate => {
    groundwork => 'tac_fillrate',
  },
  tablelock_contention => {
    groundwork => 'tl_contention',
  },
  tablelock_contention_now => {
    groundwork => 'tl_contention_now',
  },
  pct_tmp_table_on_disk => {
    groundwork => 'tmptab_on_disk',
  },
  pct_tmp_table_on_disk_now => {
    groundwork => 'tmptab_on_disk_now',
  },
);

sub print_usage () {
  print <<EOUS;
  Usage:
    $PROGNAME [-v] [-t <timeout>] [[--hostname <hostname>] 
        [--port <port> | --socket <socket>]
        --username <username> --password <password>] --mode <mode>
        [--method mysql]
    $PROGNAME [-h | --help]
    $PROGNAME [-V | --version]

  Options:
    --hostname
       the database server's hostname
    --port
       the database's port. (default: 3306)
    --socket
       the database's unix socket.
    --username
       the mysql db user
    --password
       the mysql db user's password
    --database
       the database's name. (default: information_schema)
    --warning
       the warning range
    --critical
       the critical range
    --mode
       the mode of the plugin. select one of the following keywords:
EOUS
  my $longest = length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0]);
  my $format = "       %-".
  (length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0])).
  "s\t(%s)\n";
  foreach (@modes) {
    printf $format, $_->[1], $_->[3];
  }
  printf "\n";
  print <<EOUS;
    --name
       the name of something that needs to be further specified,
       currently only used for sql statements
    --name2
       if name is a sql statement, this statement would appear in
       the output and the performance data. This can be ugly, so 
       name2 can be used to appear instead.
    --regexp
       if this parameter is used, name will be interpreted as a 
       regular expression.
    --units
       one of %, KB, MB, GB. This is used for a better output of mode=sql
       and for specifying thresholds for mode=tablespace-free
    --labelformat
       one of pnp4nagios (which is the default) or groundwork.
       It is used to shorten performance data labels to 19 characters.

  In mode sql you can url-encode the statement so you will not have to mess
  around with special characters in your Nagios service definitions.
  Instead of 
  --name="select count(*) from v\$session where status = 'ACTIVE'"
  you can say 
  --name=select%20count%28%2A%29%20from%20v%24session%20where%20status%20%3D%20%27ACTIVE%27
  For your convenience you can call check_mysql_health with the --mode encode
  option and it will encode the standard input.

  You can find the full documentation at 
  http://www.consol.de/opensource/nagios/check-mysql-health

EOUS
  
}

sub print_help () {
  print "Copyright (c) 2009 Gerhard Lausser\n\n";
  print "\n";
  print "  Check various parameters of MySQL databases \n";
  print "\n";
  print_usage();
  support();
}


sub print_revision ($$) {
  my $commandName = shift;
  my $pluginRevision = shift;
  $pluginRevision =~ s/^\$Revision: //;
  $pluginRevision =~ s/ \$\s*$//;
  print "$commandName ($pluginRevision)\n";
  print "This nagios plugin comes with ABSOLUTELY NO WARRANTY. You may redistribute\ncopies of this plugin under the terms of the GNU General Public License.\n";
}

sub support () {
  my $support='Send email to gerhard.lausser@consol.de if you have questions\nregarding use of this software. \nPlease include version information with all correspondence (when possible,\nuse output from the --version option of the plugin itself).\n';
  $support =~ s/@/\@/g;
  $support =~ s/\\n/\n/g;
  print $support;
}

sub contact_author ($$) {
  my $item = shift;
  my $strangepattern = shift;
  if ($commandline{verbose}) {
    printf STDERR
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n".
        "You found a line which is not recognized by %s\n".
        "This means, certain components of your system cannot be checked.\n".
        "Please contact the author %s and\nsend him the following output:\n\n".
        "%s /%s/\n\nThank you!\n".
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n",
            $PROGNAME, $CONTACT, $item, $strangepattern;
  }
}

%commandline = ();
my @params = (
    "timeout|t=i",
    "version|V",
    "help|h",
    "verbose|v",
    "debug|d",
    "hostname|H=s",
    "database=s",
    "port|P=s",
    "socket|S=s",
    "username|u=s",
    "password|p=s",
    "mycnf=s",
    "mycnfgroup=s",
    "mode|m=s",
    "name=s",
    "name2=s",
    "regexp",
    "perfdata",
    "warning=s",
    "critical=s",
    "dbthresholds:s",
    "absolute|a",
    "environment|e=s%",
    "method=s",
    "runas|r=s",
    "scream",
    "shell",
    "eyecandy",
    "encode",
    "units=s",
    "lookback=i",
    "3",
    "statefilesdir=s",
    "with-mymodules-dyn-dir=s",
    "report=s",
    "labelformat=s",
    "extra-opts:s");

if (! GetOptions(\%commandline, @params)) {
  print_help();
  exit $ERRORS{UNKNOWN};
}

if (exists $commandline{'extra-opts'}) {
  # read the extra file and overwrite other parameters
  my $extras = Extraopts->new(file => $commandline{'extra-opts'}, commandline =>
 \%commandline);
  if (! $extras->is_valid()) {
    printf "extra-opts are not valid: %s\n", $extras->{errors};
    exit $ERRORS{UNKNOWN};
  } else {
    $extras->overwrite();
  }
}

if (exists $commandline{version}) {
  print_revision($PROGNAME, $REVISION);
  exit $ERRORS{OK};
}

if (exists $commandline{help}) {
  print_help();
  exit $ERRORS{OK};
} elsif (! exists $commandline{mode}) {
  printf "Please select a mode\n";
  print_help();
  exit $ERRORS{OK};
}

if ($commandline{mode} eq "encode") {
  my $input = <>;
  chomp $input;
  $input =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  printf "%s\n", $input;
  exit $ERRORS{OK};
}

if (exists $commandline{3}) {
  $ENV{NRPE_MULTILINESUPPORT} = 1;
}

if (exists $commandline{timeout}) {
  $TIMEOUT = $commandline{timeout};
}

if (exists $commandline{verbose}) {
  $DBD::MySQL::Server::verbose = exists $commandline{verbose};
}

if (exists $commandline{scream}) {
#  $DBD::MySQL::Server::hysterical = exists $commandline{scream};
}

if (exists $commandline{method}) {
  # snmp or mysql cmdline
} else {
  $commandline{method} = "dbi";
}

if (exists $commandline{report}) {
  # short, long, html
} else {
  $commandline{report} = "long";
}

if (exists $commandline{labelformat}) {
  # groundwork
} else {
  $commandline{labelformat} = "pnp4nagios";
}

if (exists $commandline{'with-mymodules-dyn-dir'}) {
  $DBD::MySQL::Server::my_modules_dyn_dir = $commandline{'with-mymodules-dyn-dir'};
} else {
  $DBD::MySQL::Server::my_modules_dyn_dir = '/usr/lib/Company/plugins';
}

if (exists $commandline{environment}) {
  # if the desired environment variable values are different from
  # the environment of this running script, then a restart is necessary.
  # because setting $ENV does _not_ change the environment of the running script.
  foreach (keys %{$commandline{environment}}) {
    if ((! $ENV{$_}) || ($ENV{$_} ne $commandline{environment}->{$_})) {
      $needs_restart = 1;
      $ENV{$_} = $commandline{environment}->{$_};
      printf STDERR "new %s=%s forces restart\n", $_, $ENV{$_} 
          if $DBD::MySQL::Server::verbose;
    }
  }
  # e.g. called with --runas dbnagio. shlib_path environment variable is stripped
  # during the sudo.
  # so the perl interpreter starts without a shlib_path. but --runas cares for
  # a --environment shlib_path=...
  # so setting the environment variable in the code above and restarting the 
  # perl interpreter will help it find shared libs
}

if (exists $commandline{runas}) {
  # remove the runas parameter
  # exec sudo $0 ... the remaining parameters
  $needs_restart = 1;
  # if the calling script has a path for shared libs and there is no --environment
  # parameter then the called script surely needs the variable too.
  foreach my $important_env (qw(LD_LIBRARY_PATH SHLIB_PATH 
      ORACLE_HOME TNS_ADMIN ORA_NLS ORA_NLS33 ORA_NLS10)) {
    if ($ENV{$important_env} && ! scalar(grep { /^$important_env=/ } 
        keys %{$commandline{environment}})) {
      $commandline{environment}->{$important_env} = $ENV{$important_env};
      printf STDERR "add important --environment %s=%s\n", 
          $important_env, $ENV{$important_env} if $DBD::MySQL::Server::verbose;
    }
  }
}

if ($needs_restart) {
  my @newargv = ();
  my $runas = undef;
  if (exists $commandline{runas}) {
    $runas = $commandline{runas};
    delete $commandline{runas};
  }
  foreach my $option (keys %commandline) {
    if (grep { /^$option/ && /=/ } @params) {
      if (ref ($commandline{$option}) eq "HASH") {
        foreach (keys %{$commandline{$option}}) {
          push(@newargv, sprintf "--%s", $option);
          push(@newargv, sprintf "%s=%s", $_, $commandline{$option}->{$_});
        }
      } else {
        push(@newargv, sprintf "--%s", $option);
        push(@newargv, sprintf "%s", $commandline{$option});
      }
    } else {
      push(@newargv, sprintf "--%s", $option);
    }
  }
  if ($runas) {
    exec "sudo", "-S", "-u", $runas, $0, @newargv;
  } else {
    exec $0, @newargv;  
    # this makes sure that even a SHLIB or LD_LIBRARY_PATH are set correctly
    # when the perl interpreter starts. Setting them during runtime does not
    # help loading e.g. libclntsh.so
  }
  exit;
}

if (exists $commandline{shell}) {
  # forget what you see here.
  system("/bin/sh");
}

if (! exists $commandline{statefilesdir}) {
  if (exists $ENV{OMD_ROOT}) {
    $commandline{statefilesdir} = $ENV{OMD_ROOT}.'/var/tmp/plugin/'.$ENV{'NAGIOSENV'}.'/check_mssql_health';
  } else {
    $commandline{statefilesdir} = $STATEFILESDIR;
  }
}

if (exists $commandline{name}) {
  if ($^O =~ /MSWin/ && $commandline{name} =~ /^'(.*)'$/) {
    # putting arguments in single ticks under Windows CMD leaves the ' intact
    # we remove them
    $commandline{name} = $1;
  }
  # objects can be encoded like an url
  # with s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  if (($commandline{mode} ne "sql") || 
      (($commandline{mode} eq "sql") &&
       ($commandline{name} =~ /select%20/i))) { # protect ... like '%cac%' ... from decoding
    $commandline{name} =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
  }
  if ($commandline{name} =~ /^0$/) {
    # without this, $params{selectname} would be treated like undef
    $commandline{name} = "00";
  } 
}

$SIG{'ALRM'} = sub {
  printf "UNKNOWN - %s timed out after %d seconds\n", $PROGNAME, $TIMEOUT;
  exit $ERRORS{UNKNOWN};
};
alarm($TIMEOUT);

my $nagios_level = $ERRORS{UNKNOWN};
my $nagios_message = "";
my $perfdata = "";
if ($commandline{mode} =~ /^my-([^\-.]+)/) {
  my $param = $commandline{mode};
  $param =~ s/\-/::/g;
  push(@modes, [$param, $commandline{mode}, undef, 'my extension']);
} elsif ((! grep { $commandline{mode} eq $_ } map { $_->[1] } @modes) &&
    (! grep { $commandline{mode} eq $_ } map { defined $_->[2] ? @{$_->[2]} : () } @modes)) {
  printf "UNKNOWN - mode %s\n", $commandline{mode};
  print_usage();
  exit 3;
}
my %params = (
    timeout => $TIMEOUT,
    mode => (
        map { $_->[0] }
        grep {
           ($commandline{mode} eq $_->[1]) ||
           ( defined $_->[2] && grep { $commandline{mode} eq $_ } @{$_->[2]})
        } @modes
    )[0],
    cmdlinemode => $commandline{mode},
    method => $commandline{method} ||
        $ENV{NAGIOS__SERVICEMYSQL_METH} ||
        $ENV{NAGIOS__HOSTMYSQL_METH} || 'dbi',
    hostname => $commandline{hostname} || 
        $ENV{NAGIOS__SERVICEMYSQL_HOST} ||
        $ENV{NAGIOS__HOSTMYSQL_HOST} || 'localhost',
    database => $commandline{database} || 
        $ENV{NAGIOS__SERVICEMYSQL_DATABASE} ||
        $ENV{NAGIOS__HOSTMYSQL_DATABASE} || 'information_schema',
    port => $commandline{port}  || (($commandline{mode} =~ /^cluster/) ?
        ($ENV{NAGIOS__SERVICENDBMGM_PORT} || $ENV{NAGIOS__HOSTNDBMGM_PORT} || 1186) :
        ($ENV{NAGIOS__SERVICEMYSQL_PORT} || $ENV{NAGIOS__HOSTMYSQL_PORT} || 3306)),
    socket => $commandline{socket}  || 
        $ENV{NAGIOS__SERVICEMYSQL_SOCKET} ||
        $ENV{NAGIOS__HOSTMYSQL_SOCKET},
    username => $commandline{username} || 
        $ENV{NAGIOS__SERVICEMYSQL_USER} ||
        $ENV{NAGIOS__HOSTMYSQL_USER},
    password => $commandline{password} || 
        $ENV{NAGIOS__SERVICEMYSQL_PASS} ||
        $ENV{NAGIOS__HOSTMYSQL_PASS},
    mycnf => $commandline{mycnf} || 
        $ENV{NAGIOS__SERVICEMYSQL_MYCNF} ||
        $ENV{NAGIOS__HOSTMYSQL_MYCNF},
    mycnfgroup => $commandline{mycnfgroup} || 
        $ENV{NAGIOS__SERVICEMYSQL_MYCNFGROUP} ||
        $ENV{NAGIOS__HOSTMYSQL_MYCNFGROUP},
    warningrange => $commandline{warning},
    criticalrange => $commandline{critical},
    dbthresholds => $commandline{dbthresholds},
    absolute => $commandline{absolute},
    lookback => $commandline{lookback},
    selectname => $commandline{name} || $commandline{tablespace} || $commandline{datafile},
    regexp => $commandline{regexp},
    name => $commandline{name},
    name2 => $commandline{name2} || $commandline{name},
    units => $commandline{units},
    lookback => $commandline{lookback} || 0,
    eyecandy => $commandline{eyecandy},
    statefilesdir => $commandline{statefilesdir},
    verbose => $commandline{verbose},
    report => $commandline{report},
    labelformat => $commandline{labelformat},
);

my $server = undef;
my $cluster = undef;

if ($params{mode} =~ /^(server|my)/) {
  $server = DBD::MySQL::Server->new(%params);
  $server->nagios(%params);
  $server->calculate_result(\%labels);
  $nagios_message = $server->{nagios_message};
  $nagios_level = $server->{nagios_level};
  $perfdata = $server->{perfdata};
} elsif ($params{mode} =~ /^cluster/) {
  $cluster = DBD::MySQL::Cluster->new(%params);
  $cluster->nagios(%params);
  $cluster->calculate_result(\%labels);
  $nagios_message = $cluster->{nagios_message};
  $nagios_level = $cluster->{nagios_level};
  $perfdata = $cluster->{perfdata};
}

printf "%s - %s", $ERRORCODES{$nagios_level}, $nagios_message;
printf " | %s", $perfdata if $perfdata;
printf "\n";
exit $nagios_level;


__END__


