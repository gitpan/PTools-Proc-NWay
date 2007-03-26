# -*- Perl -*-
#
# File:  Makefile.PL
# Desc:  Make the makefile for the PTools-Proc-NWay distribution
# Date:  Sat Mar 24 13:59:40 2007
#
use inc::Module::Install;

name		'PTools-Proc-NWay';
author		'Chris Cobb <nospamplease@ccobb.net>';
license 	'perl';
all_from	'lib/PTools/Proc/NWay.pm';
tests		't/*.t';   ##  t/*/*.t t/*/*/*.t';

# When building this distribution
#no_index	directory 	=> 'eg';
build_requires	Test::More	=> 0;

# Standard modules needed
requires	strict		=> 0;
requires	warnings	=> 0;

# Additional modules needed
requires	POE::Session		=> 0;
requires	POE::Filter::Reference	=> 0;
requires	POE::Wheel::Run		=> 0;
requires	PTools::Counter		=> 0.08;
requires	PTools::Date::Format	=> 0;
requires	PTools::Debug		=> 0;
requires	PTools::Loader		=> 0;
requires	PTools::Local		=> 0;
requires	PTools::Options		=> 0.14;
requires	PTools::Proc::Backtick	=> 0;
requires	PTools::SDF::ARRAY	=> 0;
requires	PTools::SDF::Lock::Advisory	=> 0;
requires	PTools::SDF::SDF	=> 0.30;
requires	PTools::String		=> 0;
requires	PTools::Time::Elapsed	=> 0;

WriteAll();
