package DBIx::Lite::ResultSet;
use strict;
use warnings;

use Carp qw(croak);
use Clone qw(clone);
use Data::Page;
use List::MoreUtils qw(firstval uniq);
use vars qw($AUTOLOAD);
$Carp::Internal{$_}++ for __PACKAGE__;

sub _new {
    my $class = shift;
    my (%params) = @_;
    
    my $self = {
        joins           => delete $params{joins} || [],
        where           => delete $params{where} || [],
        select          => delete $params{select} || ['me.*'],
        group_by        => delete $params{group_by},
        having          => delete $params{having},
        order_by        => delete $params{order_by},
        limit           => delete $params{limit},
        offset          => delete $params{offset},
        rows_per_page   => delete $params{rows_per_page} || 10,
        page            => delete $params{page},
        cur_table       => delete $params{cur_table} || $params{table},
    };
    
    for (qw(dbix_lite table)) {
        $self->{$_} = delete $params{$_} or croak "$_ argument needed";
    }
    
    !%params
        or croak "Unknown options: " . join(', ', keys %params);
    
    bless $self, $class;
    $self;
}

for my $methname (qw(group_by having order_by limit offset rows_per_page page)) {
    no strict 'refs';
    *$methname = sub {
        my $self = shift;
    
        my $new_self = $self->_clone;
        $new_self->{$methname} = $methname =~ /^(group_by|order_by)$/ ? [@_] : $_[0];
        $new_self->{pager}->current_page($_[0]) if $methname eq 'page' && $new_self->{pager};
        $new_self;
    };
}

sub _clone {
    my $self = shift;
    (ref $self)->_new(
        map { $_ => /^(?:dbix_lite|table|cur_table)$/ ? $self->{$_} : clone($self->{$_}) }
            grep !/^(?:sth|pager)$/, keys %$self,
    );
}

sub select {
    my $self = shift;

    my $new_self = $self->_clone;
    $new_self->{select} = @_ ? [@_] : undef;
    
    $new_self;
}

sub select_also {
    my $self = shift;
    return $self->select(@{$self->{select}}, @_);
}

sub pager {
    my $self = shift;
    if (!$self->{pager}) {
        $self->{pager} ||= Data::Page->new;
        $self->{pager}->total_entries($self->page(undef)->count);
        $self->{pager}->entries_per_page($self->{rows_per_page});
        $self->{pager}->current_page($self->{page});
    }
    return $self->{pager};
}

sub search {
    my $self = shift;
    my ($where) = @_;
    
    my $new_self = $self->_clone;
    push @{$new_self->{where}}, $where;
    $new_self;
}

sub find {
    my $self = shift;
    my ($where) = @_;
    
    if (!ref $where && (my @pk = $self->{table}->pk)) {
        $where = { map +(shift(@pk) => $_), @_ };
    }
    return $self->search($where)->single;
}

sub select_sql {
    my $self = shift;
    
    my $quote = sub { $self->{dbix_lite}->{abstract}->_quote(@_) };
    
    # column names
    my @cols = ();
    my $have_scalar_ref = 0;
    my $cur_table_prefix = $self->_table_prefix($self->{cur_table}{name}, 'select');
    foreach my $col (grep defined $_, @{$self->{select}}) {
        my ($expr, $as) = ref $col eq 'ARRAY' ? @$col : ($col, undef);
        $expr =~ s/^[^.]+$/$cur_table_prefix\.$&/ if !ref($expr);
        if (ref $expr eq 'SCALAR') {
            $expr = $$expr;
            $have_scalar_ref = 1;
        }
        push @cols, $expr . ($as ? "|$as" : "");
    }
    
    # always retrieve our primary key if provided and no col name is a scalar ref
    if (!$have_scalar_ref && (my @pk = $self->{cur_table}->pk)) {
        if (not firstval { "$cur_table_prefix.*" eq $_ } @cols) {
            $_ =~ s/^[^.]+$/$cur_table_prefix\.$&/ for @pk;
            unshift @cols, @pk;
        }
    }
    
    # joins
    my @joins = ();
    foreach my $join (@{$self->{joins}}) {
        my ($table_name, $table_alias) = @{$join->[2]};
        my %cond = ();
        my $left_table_prefix = $self->_table_prefix($join->[1]{name}, 'select');
        while (my ($col1, $col2) = each %{$join->[3]}) {
            $col1 =~ s/^[^.]+$/$left_table_prefix\.$&/;
            $col2 = ($table_alias || $quote->($table_name)) . ".$col2"
                unless ref $col2 || $col2 =~ /\./;
            $cond{$col1} = ref($col2) ? $col2 : \ "= $col2";
        }
        push @joins, {
            operator    => $join->[0] eq 'inner' ? '<=>' : '=>',
            condition   => \%cond,
        };
        push @joins, $table_name . ($table_alias ? "|$table_alias" : "");
    }
    
    # paging
    if ($self->{page}) {
        $self->{limit} = $self->{rows_per_page};
        $self->{offset} = $self->pager->skipped;
    }
    
    # ordering
    if ($self->{order_by}) {
        $self->{order_by} = [$self->{order_by}]
            unless ref $self->{order_by} eq 'ARRAY';
    }
    
    return $self->{dbix_lite}->{abstract}->select(
        -columns    => [ uniq @cols ],
        -from       => [ -join => $self->{table}{name} . "|me", @joins ],
        -where      => { -and => $self->{where} },
        $self->{group_by}   ? (-group_by    => $self->{group_by})   : (),
        $self->{having}     ? (-having      => $self->{having})     : (),
        $self->{order_by}   ? (-order_by    => $self->{order_by})   : (),
        $self->{limit}      ? (-limit       => $self->{limit})      : (),
        $self->{offset}     ? (-offset      => $self->{offset})     : (),
    );
}

sub select_sth {
    my $self = shift;
    
    my ($sql, @bind) = $self->select_sql;
    return $self->{dbix_lite}->dbh->prepare($sql) || undef, @bind;
}

sub insert_sql {
    my $self = shift;
    my $insert_cols = shift;
    ref $insert_cols eq 'HASH' or croak "insert_sql() requires a hashref";
    
    return $self->{dbix_lite}->{abstract}->insert(
        $self->{table}{name}, $insert_cols,
    );
}

sub insert_sth {
    my $self = shift;
    my $insert_cols = shift;
    ref $insert_cols eq 'HASH' or croak "insert_sth() requires a hashref";
    
    my ($sql, @bind) = $self->insert_sql($insert_cols);
    return $self->{dbix_lite}->dbh->prepare($sql) || undef, @bind;
}

sub insert {
    my $self = shift;
    my $insert_cols = shift;
    ref $insert_cols eq 'HASH' or croak "insert() requires a hashref";
    
    my $res;
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->insert_sth($insert_cols);
        $res = $sth->execute(@bind);
    });
    return undef if !$res;
    
    if (my $pk = $self->{table}->autopk) {
        $insert_cols = clone $insert_cols;
        $insert_cols->{$pk} = $self->{dbix_lite}->_autopk($self->{table}{name})
            if !exists $insert_cols->{$pk};
    }
    return $self->_inflate_row($insert_cols);
}

sub update_sql {
    my $self = shift;
    my $update_cols = shift;
    ref $update_cols eq 'HASH' or croak "update_sql() requires a hashref";
    
    my $update_where = { -and => $self->{where} };
    
    if ($self->{cur_table}{name} ne $self->{table}{name}) {
        my @pk = $self->{cur_table}->pk
            or croak "No primary key defined for " . $self->{cur_table}{name} . "; cannot update using relationships";
        @pk == 1
            or croak "Update across relationships is not allowed with multi-column primary keys";
        
        my $fq_pk = $self->_table_prefix($self->{cur_table}{name}, 'update') . "." . $pk[0];
        $update_where = {
            $fq_pk => {
                -in => \[ $self->select($pk[0])->select_sql ],
            },
        };
    }
    
    return $self->{dbix_lite}->{abstract}->update(
        $self->_table_alias($self->{cur_table}{name}, $self->_table_prefix($self->{cur_table}{name}, 'update')),
        $update_cols, $update_where,
    );
}

sub update_sth {
    my $self = shift;
    my $update_cols = shift;
    ref $update_cols eq 'HASH' or croak "update_sth() requires a hashref";
    
    my ($sql, @bind) = $self->update_sql($update_cols);
    return $self->{dbix_lite}->dbh->prepare($sql) || undef, @bind;
}

sub update {
    my $self = shift;
    my $update_cols = shift;
    ref $update_cols eq 'HASH' or croak "update() requires a hashref";
    
    my $res;
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->update_sth($update_cols);
        $res = $sth->execute(@bind);
    });
    return $res;
}

sub find_or_insert {
    my $self = shift;
    my $cols = shift;
    ref $cols eq 'HASH' or croak "find_or_insert() requires a hashref";
    
    my $object;
    $self->{dbix_lite}->txn(sub {
        if (!($object = $self->find($cols))) {
            $object = $self->insert($cols);
        }
    });
    return $object;
}

sub delete_sql {
    my $self = shift;
    
    my $delete_where = { -and => $self->{where} };
    
    if ($self->{cur_table}{name} ne $self->{table}{name}) {
        my @pk = $self->{cur_table}->pk
            or croak "No primary key defined for " . $self->{cur_table}{name} . "; cannot delete using relationships";
        @pk == 1
            or croak "Delete across relationships is not allowed with multi-column primary keys";
        
        my $fq_pk = $self->_table_prefix($self->{cur_table}{name}, 'delete') . "." . $pk[0];
        $delete_where = {
            $fq_pk => {
                -in => \[ $self->select($pk[0])->select_sql ],
            },
        };
    }
    
    return $self->{dbix_lite}->{abstract}->delete(
        $self->{cur_table}{name},
        $delete_where,
    );
}

sub delete_sth {
    my $self = shift;
    
    my ($sql, @bind) = $self->delete_sql;
    return $self->{dbix_lite}->dbh->prepare($sql) || undef, @bind;
}

sub delete {
    my $self = shift;
    
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->delete_sth;
        $sth->execute(@bind);
    });
}

sub single {
    my $self = shift;
    
    my $row;
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->select_sth;
        $sth->execute(@bind);
        $row = $sth->fetchrow_hashref;
    });
    return $row ? $self->_inflate_row($row) : undef;
}

sub single_value {
    my $self = shift;
    
    my $value;
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->select_sth;
        $sth->execute(@bind);
        ($value) = $sth->fetchrow_array;
    });
    return $value;
}

sub all {
    my $self = shift;
    
    my $rows;
    $self->{dbix_lite}->dbh_do(sub {
        my ($sth, @bind) = $self->select_sth;
        $sth->execute(@bind);
        $rows = $sth->fetchall_arrayref({});
    });
    return map $self->_inflate_row($_), @$rows;
}

sub next {
    my $self = shift;
    
    $self->{dbix_lite}->dbh_do(sub {
        ($self->{sth}, my @bind) = $self->select_sth;
        $self->{sth}->execute(@bind);
    }) if !$self->{sth};
    
    my $row = $self->{sth}->fetchrow_hashref or return undef;
    return $self->_inflate_row($row);
}

sub count {
    my $self = shift;
    
    my $count;
    $self->{dbix_lite}->dbh_do(sub {
        my $count_rs = ($self->_clone)->select(\ "-COUNT(*)");
        my ($sth, @bind) = $count_rs->select_sth;
        $sth->execute(@bind);
        $count = +($sth->fetchrow_array)[0];
    });
    return $count;
}

sub column_names {
    my $self = shift;

    $self->{dbix_lite}->dbh_do(sub {
        ($self->{sth}, my @bind) = $self->select_sth;
        $self->{sth}->execute(@bind);
    }) if !$self->{sth};

    my $c = $self->{sth}->{NAME};
    return wantarray ? @$c : $c;
}

sub get_column {
    my $self = shift;
    my $column_name = shift or croak "get_column() requires a column name";
    
    my @values = ();
    $self->{dbix_lite}->dbh_do(sub {
        my $rs = ($self->_clone)->select($column_name);
        my ($sql, @bind) = $rs->select_sql;
    
        @values = @{$self->{dbix_lite}->dbh->selectcol_arrayref($sql, {}, @bind)};
    });
    return @values;
}

sub inner_join {
    my $self = shift;
    return $self->_join('inner', @_);
}

sub left_join {
    my $self = shift;
    return $self->_join('left', @_);
}

sub _join {
    my $self = shift;
    my ($type, $table_name, $condition, $options) = @_;
    $options ||= {};
    $table_name = [ $table_name, undef ] if ref $table_name ne 'ARRAY';
    
    my $new_self = $self->_clone;
    push @{$new_self->{joins}}, [
        $type,
        $self->{cur_table},
        $table_name,
        $condition,
    ] if !$options->{prevent_duplicates} || !grep { $_->[2][0] eq $table_name->[0] } @{$new_self->{joins}};
    $new_self;
}

sub _table_prefix {
    my $self = shift;
    my ($table_name, $op) = @_;
    return ($op eq 'select' && $table_name eq $self->{table}{name}) ? 'me' : $table_name;
}

sub _table_alias {
    my $self = shift;
    my ($table_name, $table_alias) = @_;
    
    if ($table_name eq $table_alias) {
        return $table_name;
    } else {
        return $self->{dbix_lite}->{abstract}->table_alias($table_name, $table_alias);
    }
}

sub _inflate_row {
    my $self = shift;
    my ($hashref) = @_;
    
    my $package = $self->{cur_table}->class || 'DBIx::Lite::Row';
    return $package->_new(
        dbix_lite   => $self->{dbix_lite},
        table       => $self->{cur_table},
        data        => $hashref,
    );
}

sub AUTOLOAD {
    my $self = shift or return undef;
    
    # Get the called method name and trim off the namespace
    (my $method = $AUTOLOAD) =~ s/.*:://;
	
    if (my $rel = $self->{cur_table}{has_many}{$method}) {
        my $new_self = $self->inner_join($rel->[0], $rel->[1])->select("$method.*");
        $new_self->{cur_table} = $self->{dbix_lite}->schema->table($rel->[0]);
        bless $new_self, $new_self->{cur_table}->resultset_class || __PACKAGE__;
        return $new_self;
    }
    
    croak "No $method method is provided by this " . ref($self) . " object";
}

sub DESTROY {}

1;

=head1 OVERVIEW

This class is not supposed to be instantiated manually. You usually get your 
first ResultSet object by calling the C<table()> method on your L<DBIx::Lite>
object:

    my $books_rs = $dbix->table('books');

and then you can chain methods on it to build your query:

    my $old_books_rs = $books_rs
        ->search({ year => { '<' => 1920 } })
        ->order_by('year');

=head1 BUILDING THE QUERY

=head2 search

This method accepts a search condition using the L<SQL::Abstract> syntax and 
returns a L<DBIx::Lite::ResultSet> object with the condition applied.

    my $young_authors_rs = $authors_rs->search({ age => { '<' => 18 } });

Multiple C<search()> methods can be chained; they will be merged using the
C<AND> operator:

    my $rs = $books_rs->search({ year => 2012 })->search({ genre => 'philosophy' });

=head2 select

This method accepts a list of column names to retrieve. The default is C<*>, so
all columns will be retrieved. It returns a L<DBIx::Lite::ResultSet> object to 
allow for further method chaining.

    my $rs = $books_rs->select('title', 'year');

If you want to rename a column, pass it as an arrayref:

    my $rs = $books_rs->select(['title' => 'book_title'], 'year');
    # SELECT title AS book_title, year FROM books ...

=head2 select_also

This method works like L<select> but it adds the passed columns to the ones already
selected. It is useful when joining:

    my $books_authors_rs = $books_rs
        ->left_join('authors', { author_id => 'id' })
        ->select_also(['authors.name' => 'author_name']);

=head2 order_by

This method accepts a list of columns for sorting. It returns a L<DBIx::Lite::ResultSet>
object to allow for further method chaining.
Columns can be prefixed with C<+> or C<-> to indicate sorting direction (C<+> is C<ASC>,
C<-> is C<DESC>) or they can be expressed using the L<SQL::Abstract> syntax
(C<<{-asc => $column_name}>>).

    my $rs = $books_rs->order_by('year');
    my $rs = $books_rs->order_by('+genre', '-year');

=head2 group_by

This method accepts a list of columns to insert in the SQL C<GROUP BY> clause.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $dbix
        ->table('books')
        ->select('genre', \ 'COUNT(*)')
        ->group_by('genre');

=head2 having

This method accepts a search condition to insert in the SQL C<HAVING> clause
(in combination with L<group_by>).
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $dbix
        ->table('books')
        ->select('genre', \ 'COUNT(*)')
        ->group_by('genre')
        ->having({ year => 2012 });

=head2 limit

This method accepts a number of rows to insert in the SQL C<LIMIT> clause (or whatever
your RDBMS dialect uses for that purpose). See the L<page> method too if you want an
easier interface for pagination.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $books_rs->limit(5);

=head2 offset

This method accepts the index of the first row to retrieve; it will be used in the SQL
C<OFFSET> clause (or whatever your RDBMS dialect used for that purpose).
See the L<page> method too if you want an easier interface for pagination.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $books_rs->limit(5)->offset(10);

=head2 inner_join

This method accepts the name of a column to join and a set of join conditions.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $books_rs->inner_join('authors', { author_id => 'id' });

The join conditions are in the form I<my columns> => I<their columns>. In the above
example, we're selecting from the I<books> table to the I<authors> table, so the join 
condition maps I<my> C<author_id> column to I<their> C<id> column.

The third, optional, argument can be a hashref with options. The only supported one
is currently I<prevent_duplicates>: set this to true to have DBIx::Lite check whether
you already joined the same table in this query. If you did, this join will be skipped:

    my $rs = $books_rs->inner_join('authors', { author_id => 'id' }, { prevent_duplicates => 1 });

=head2 left_join

This method works like L<inner join> except it applies a C<LEFT JOIN> instead of an
C<INNER JOIN>.

=head1 RETRIEVING RESULTS

=head2 all

This method will execute the C<SELECT> query and will return a list of 
L<DBIx::Lite::Row> objects.

    my @books = $books_rs->all;

=head2 single

This method will execute the C<SELECT> query and will return a L<DBIx::Lite::Row> 
object populated with the first row found; if none is found, undef is returned.

    my $book = $dbix->table('books')->search({ id => 20 })->single;

=head2 find

This method is a shortcut for L<search> and L<single>. The following statement
is equivalent to the one in the previous example:

    my $book = $dbix->table('books')->find({ id => 20 });

If you specified a primary key for the table (see the docs for L<DBIx::Lite::Schema>)
you can just pass its value(s) to C<find>:

    $dbix->schema->table('books')->pk('id');
    my $book = $dbix->table('books')->find(20);

=head2 count

This method will execute a C<SELECT COUNT(*)> query and will return the resulting 
number.

    my $book_count = $books_rs->count;

=head2 next

This method is a convenient iterator to retrieve your results efficiently without 
loading all of them in memory.

    while (my $book = $books_rs->next) {
        ...
    }

Note that you have to store your query before iteratingm like in the example above.
The following syntax will always retrieve just the first row in an endless loop:

    while (my $book = $dbix->table('books')->next) {
        ...
    }

=head2 column_names

This method returns a list of column names.
It returns array on list context and array reference on scalar context.

    my @book_columns = $books_rs->column_names;
    my $book_columns = $books_rs->column_names; # array reference

=head2 get_column

This method accepts a column name to fetch. It will execute a C<SELECT> query to
retrieve that column only and it will return a list with the values.

    my @book_titles = $books_rs->get_column('title');

=head2 single_value

This method returns the value of the first cell of the first row. It's useful in
situations like this:

    my $max = $books_rs->select(\"MAX(pages)")->single_value;

=head1 MANIPULATING ROWS

=head2 insert

This method accepts a hashref with column values to pass to the C<INSERT> SQL command.
It returns the inserted L<DBIx::Lite::Row> object. If you specified an autoincrementing
primary key and your database driver is supported, L<DBIx::Lite> will retrieve it and 
populate the resulting object accordingly.

    my $book = $dbix
        ->table('books')
        ->insert({ name => 'Camel Tales', year => 2012 });

=head2 find_or_insert

This method works like L<insert> but it will perform a L<find> search to check that
no row already exists for the supplied column values. If a row is found it is returned,
otherwise a SQL C<INSERT> is performed and the inserted row is returned.

    my $book = $dbix
        ->table('books')
        ->find_or_insert({ name => 'Camel Tales', year => 2012 });

=head2 update

This method accepts a hashref with column values to pass to the C<UPDATE> SQL command.

    $dbix->table('books')
        ->search({ year => { '<' => 1920 } })
        ->update({ very_old => 1 });

=head2 delete

This method performs a C<DELETE> SQL command.

    $books_rs->delete;

=head2 select_sql

This method returns a list having the SQL C<SELECT> statement as the first item, 
and bind values as subsequent values. No query is executed. This method
also works when no C<$dbh> or connection data is supplied to L<DBIx::Lite>.

    my ($sql, @bind) = $books_rs->select_sql;

=head2 select_sth

This methods prepares the SQL C<SELECT> statement and returns it along with bind values.

    my ($sth, @bind) = $books_rs->select_sth;

=head2 insert_sql

This method works like L<insert> but it will just return a list having the SQL statement
as the first item, and bind values as subsequent values. No query is executed. This method
also works when no C<$dbh> or connection data is supplied to L<DBIx::Lite>.

    my ($sql, @bind) = $dbix
        ->table('books')
        ->insert_sql({ name => 'Camel Tales', year => 2012 });

=head2 insert_sth

This methods prepares the SQL C<INSERT> statement and returns it along with bind values.

   my ($sth, @bind) = $dbix
        ->table('books')
        ->insert_sth({ name => 'Camel Tales', year => 2012 });

=head2 update_sql

This method works like L<update> but it will just return a list having the SQL statement
as the first item, and bind values as subsequent values. No query is executed. This method
also works when no C<$dbh> or connection data is supplied to L<DBIx::Lite>.

    my ($sql, @bind) = $books_rs->update_sql({ genre => 'tennis' });

=head2 update_sth

This method prepares the SQL C<UPDATE> statement and returns it along with bind values.

    my ($sth, @bind) = $books_rs->update_sth({ genre => 'tennis' });

=head2 delete_sql

This method works like L<delete> but it will just return a list having the SQL statement
as the first item, and bind values as subsequent values. No query is executed. This method
also works when no C<$dbh> or connection data is supplied to L<DBIx::Lite>.

    my ($sql, @bind) = $books_rs->delete_sql;

=head2 delete_sth

This method prepares the SQL C<DELETE> statement and returns it along with bind values.

    my ($sth, @bind) = $books_rs->delete_sth;

=head1 PAGING

=head2 page

This method accepts a page number. It defaults to 0, meaning no pagination. First page
has index 1. Usage of this method implies L<limit> and L<offset>, so don't call them.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $books_rs->page(3);

=head2 rows_per_page

This method accepts the number of rows for each page. It defaults to 10, and it has
no effect unless L<page> is also called.
It returns a L<DBIx::Lite::ResultSet> object to allow for further method chaining.

    my $rs = $books_rs->rows_per_page(50)->page(3);

=head2 pager

This method returns a L<Data::Page> object already configured for the current query.
Calling this method will execute a L<count> query to retrieve the total number of 
rows.

    my $rs = $books_rs->rows_per_page(50)->page(3);
    my $page = $rs->pager;
    printf "Showing results %d - %d (total: %d)\n",
        $page->first, $page->last, $page->total_entries;
    while (my $book = $rs->next) {
        ...
    }

=cut
