[% USE AuthorisedValues %]

[%#-
This include takes two parameters: an item structure
and an optional loan (issue) structure.  The issue
structure is used by course reserves pages, which do
not use an API to fetch items that populates item.datedue.
-%]

[% IF ( item.itemlost ) %]
    [% av_lib_include = AuthorisedValues.GetByCode( 'LOST', item.itemlost, 1 ) %]
    [% IF ( av_lib_include ) %]
        [% av_lib_include %]
    [% ELSE %]
        [% IF ( item.lostimageurl ) %]
            <img src="[% item.lostimageurl %]" alt="[% item.lostimagelabel %]" title="[% item.lostimagelabel %]">
        [% ELSE %]
            Item lost
        [% END %]
    [% END %]
[% ELSIF ( item.datedue || issue.date_due ) %]
    [% IF ( OPACShowCheckoutName ) %]
        Checked out to [% item.cardnumber %] [% item.firstname %] [% item.surname %]
    [% ELSE %]
        Checked out
    [% END %]
[% ELSIF ( item.transfertwhen ) %]
    In transit from [% item.transfertfrom %]
    to [% item.transfertto %] since [% item.transfertwhen %]
[% ELSIF ( item.waiting ) %]
    On hold
[% ELSIF ( item.withdrawn ) %]
    Item withdrawn
[% ELSIF ( item.itemnotforloan ) %]
    [% IF ( item.notforloanvalueopac ) %]
        [% item.notforloanvalueopac %] [% IF ( item.restrictedopac ) %]<span class="restricted">([% item.restrictedopac %])</span>[% END %]
    [% ELSE %]
        Not for loan [% IF ( item.restrictedopac ) %]<span class="restricted">([% item.restrictedopac %])</span>[% END %]
    [% END %]
[% ELSIF ( item.notforloan_per_itemtype ) %]
    Not for loan [% IF ( item.restrictedopac ) %]<span class="restricted">([% item.restrictedopac %])</span>[% END %]
[% ELSIF ( item.damaged ) %]
    [% av_lib_include = AuthorisedValues.GetByCode( 'DAMAGED', item.damaged, 1 ) %]
    [% IF av_lib_include %]
        [% av_lib_include %]
    [% ELSE %]
        Item damaged
    [% END %]
[% ELSE %]
    Available [% IF ( item.restrictedopac ) %]<span class="restricted">([% item.restrictedopac %])</span>[% END %]
[% END %]
