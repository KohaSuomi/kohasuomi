#!/usr/bin/perl

# Copyright Katipo Communications 2002
# Copyright Biblibre 2007,2010
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


use strict;
use CGI;
use C4::Members;
use C4::Circulation;
use C4::Auth;
use C4::Output;
use C4::Budgets qw(GetCurrency);
use warnings;

use Koha::Payment::Online;
use Koha::Vetuma::Config;
use Koha::Vetuma::Message;

my $query = new CGI;
my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
    {
        template_name   => "opac-account.tmpl",
        query           => $query,
        type            => "opac",
        authnotrequired => 0,
        debug           => 1,
    }
);

# get borrower information ....
my $borr = GetMemberDetails( $borrowernumber );
my @bordat;
$bordat[0] = $borr;

$template->param( BORROWER_INFO => \@bordat );

#get account details
my ( $total , $accts, $numaccts) = GetMemberAccountRecords( $borrowernumber );

for ( my $i = 0 ; $i < $numaccts ; $i++ ) {
    $accts->[$i]{'amount'} = sprintf( "%.2f", $accts->[$i]{'amount'} || '0.00');
    if ( $accts->[$i]{'amount'} >= 0 ) {
        $accts->[$i]{'amountcredit'} = 1;
    }
    $accts->[$i]{'amountoutstanding'} =
      sprintf( "%.2f", $accts->[$i]{'amountoutstanding'} || '0.00' );
    if ( $accts->[$i]{'amountoutstanding'} >= 0 ) {
        $accts->[$i]{'amountoutstandingcredit'} = 1;
    }
}

# add the row parity
my $num = 0;
foreach my $row (@$accts) {
    $row->{'even'} = 1 if $num % 2 == 0;
    $row->{'odd'}  = 1 if $num % 2 == 1;
    $num++;
}

# Vetuma on-line payments related stuff KD#1446 (if Vetuma is configured, use it)

my $vetumaConfig = Koha::Vetuma::Config->new()->loadConfigXml();

# minAmount is replaced with C4::Context->preference("OnlinePaymentsMinTotal")

# my $minAmount = 0;
# if(defined $vetumaConfig->{settings}->{min_amount} && $vetumaConfig->{settings}->{min_amount} > 0){
#    $minAmount = $vetumaConfig->{settings}->{min_amount};
# }

if (defined $vetumaConfig->{settings}->{request_url}) {
  my $messages = Koha::Vetuma::Message->new();
  $messages->setSession($query->cookie("CGISESSID"));
  my $messagesJson = $messages->getMessages();
  $template->param (
    messages_json => $messagesJson,
    vetuma_enabled => 1
  );
}

# Vetuma stuff ends. 

$template->param (
    ACCOUNT_LINES => $accts,
    total => sprintf( "%.2f", $total ),
	accountview => 1,
    currency => C4::Budgets::GetCurrency(),
    online_payments_enabled => Koha::Payment::Online::is_online_payment_enabled(C4::Branch::mybranch()),
    minimumSum => C4::Context->preference("OnlinePaymentMinTotal")
);

output_html_with_http_headers $query, $cookie, $template->output, undef, { force_no_caching => 1 };

