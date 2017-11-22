* Title: luckyluke.rb - Voting Bot
* Tags: radiator ruby steem steemdev curation
* Notes: 

Lucky Luke is a reimplementation of [Dr. Phil](https://gist.github.com/inertia186/61bcc2b821aa5acb24f7fc88921950c7), but instead of voting for new articles, it votes for posts mentioned in the memo field of a `transfer` operation.  By default, it votes for any `transfer` sent to @booster but you can configure any bot that receives pay-for-vote transfers (or even @null).  You can also set a minimum transfer amount to ignore small amounts.

#### New Features

  * `vote_weight` can now be either a static percentage (like `100.00 %`) or `dynamic`.  When using `dynamic`, the vote is compared to account history.  If the transfer is equal to or greater than the maximum transfer in history, the vote will be 100%.  Otherwise, the transfer amount is divided by the maximum.  History is set by `history_limit`.
  * `reserve_voting_power` will allow the bot to exceed `min_voting_power` by the amount specified when a transfer is equal to or greater than the maximum transfer in history.
  * Added `luckyluke-disabled-voters.txt` to keep track of accounts that can no longer vote due to things like keys changing.  This file may be appended to live in order to disable/enable voting on certain accounts without restarting the bot.

#### Features

* YAML config.
  * `voting_rules`
    * `min_transfer` allows you to specify the minimum amount in the `transfer` to vote on.
    * `min_wait` and `max_wait` (in minutes) so that you can fine-tune voting delay.
    * `enable_comments` option to vote for post replies (default false).
    * `max_rep` option, useful for limiting votes to newer authors (default 99.9).
    * `min_rep` can accept either a static reputation or a dynamic property.
      * Existing static reputation still supported, e.g.: `25.0`
      * Dynamic reputation, e.g.: `dynamic:100`.  This will occasionally query the top 100 trending posts and use the minimum author reputation.
    * `min_voting_power` to create a floor with will allow the voter to recharge over time without having to stop the script.
    * `vote_signals` account list.
      * Optionally allows multiple bot instances to cooperate by avoiding vote swarms.
      * If enabled, this feature allows cooperation without sharing keys.
    * `only_tags` (optional) which only votes on posts that include these tags.
    * `only_above_average_transfers` allows voters to only vote if the transfer is above average for that bot.
    * `history_limit` used when `only_above_average_transfers` is true or `vote_weight` is `dynamic` to set how far back to calculate.
    * `max_transfer` allows you to specify the maximum amount in the `transfer` to vote on, which is useful when running multiple instances with voting tiers.
    * `max_age` allows you to only upvote newer content, for example, avoiding posts that are about to become locked.
    * Optionally configure `voters` as a separate filename.  E.g:
      * `voters: voters.txt`
        * The format for the file is just: `account wif` (no leading dash, separated by space)
      * Or continue to use the previous format.
    * Also optional support for separate files in each (format one per line or separated by space or both):
        * `skip_accounts`
        * `skip_tags`
        * `flag_signals`
        * `vote_signals`
* `bots` is a list of bots to watch `transfer` operations for.
* Skip posts with declined payout.
* Skip posts that already have votes from external scripts and posts that were edited.
* Argument called `replay:` allows a replay of *n* blocks allowing you to catch up to the present.
  * E.g.: `ruby luckyluke.rb replay:90` will replay the last 90 blocks (about 4.5 minutes).
* Thread management
  * Counter displayed so you know what kind of impact `^C` will have.
  * This also keeps the number of threads down when authors edit before Lucky Luke votes.
* Streaming on Last Irreversible Block Number, just to be fancy.
* Checking for new HF18 `cashout_time` value (if present).
  * This will skip voting when authors edit their old archived posts.

#### Overview

The goal is to vote before the pay-for-vote bot.  To achieve this, Lucky Luke watches for `transfer` operations.

You might configure the bot to only watch for transfers over `10.000 SBD`, for example.  The bot will also use a few other rules like to avoid voting for declined payouts and automatically suspend voting if it needs to recharge.

---

#### Install

To use this [Radiator](https://steemit.com/steem/@inertia/radiator-steem-ruby-api-client) bot:

##### Linux

```bash
$ sudo apt-get update
$ sudo apt-get install ruby-full git openssl libssl1.0.0 libssl-dev
$ sudo apt-get upgrade
$ gem install bundler
```

##### macOS

```bash
$ gem install bundler
```
You can try the system version of `ruby`, but if you have issues with that, use this [how-to](https://steemit.com/ruby/@inertia/how-to-configure-your-mac-to-do-ruby-on-rails-development), and come back to this installation at Step 4:

I've tested it on various versions of ruby.  The oldest one I got it to work was:

`ruby 2.0.0p645 (2015-04-13 revision 50299) [x86_64-darwin14.4.0]`

##### Setup

First, clone this gist and install the dependencies:

```bash
$ git clone https://gist.github.com/07cfb044f625beb22724371b85cea0e4.git luckyluke
$ cd luckyluke
$ bundle install
```

Then run it:

```bash
$ ruby luckyluke.rb
```

Lucky Luke will now do it's thing.  Check here to see an updated version of this bot:

https://gist.github.com/inertia186/07cfb044f625beb22724371b85cea0e4

---

#### Upgrade

Typically, you can upgrade to the latest version by this command, from the original directory you cloned into:

```bash
$ git pull
```

Usually, this works fine as long as you haven't modified anything.  If you get an error, try this:

```
$ git stash --all
$ git pull --rebase
$ git stash pop
```

If you're still having problems, I suggest starting a new clone.

---

#### Troubleshooting

##### Problem: What does this error mean?

```
luckyluke.yml:1: syntax error, unexpected ':', expecting end-of-input
```

##### Solution: You ran `ruby luckyluke.yml` but you should run `ruby luckyluke.rb`.

---

##### Problem: Everything looks ok, but every time Lucky Luke tries to vote, I get this error:

```
Unable to vote with <account>.  Invalid version
```

##### Solution: You're trying to vote with an invalid key.

Make sure the `.yml` file `voter` items have the account name, followed by a space, followed by the account's WIF posting key.  Also make sure you have removed the example accounts (`social` and `bad.account` are just for testing).

##### Problem: The node I'm using is down.

Is there a list of nodes?

##### Solution: Yes, special thanks to @ripplerm.

https://ripplerm.github.io/steem-servers/

---

<center>
  <img src="http://i.imgur.com/IGRR31s.png" />
</center>

See my previous Ruby How To posts in: [#radiator](https://steemit.com/created/radiator) [#ruby](https://steemit.com/created/ruby)

## Get in touch!

If you're using Lucky Luke, I'd love to hear from you.  Drop me a line and tell me what you think!  I'm @inertia on STEEM and [SteemSpeak](http://discord.steemspeak.com).
  
## License

I don't believe in intellectual "property".  If you do, consider Lucky Luke as licensed under a Creative Commons [![CC0](http://i.creativecommons.org/p/zero/1.0/80x15.png)](http://creativecommons.org/publicdomain/zero/1.0/) License.
