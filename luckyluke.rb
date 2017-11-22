# Lucky Luke (luckyluke) watches transfers sent to pay-for-vote bots and tries
# to vote for the content first (front-running).
#
# See: https://steemit.com/radiator/@inertia/luckyluke-rb-voting-bot

require 'rubygems'
require 'bundler/setup'
require 'yaml'
# require 'irb'

Bundler.require

defined? Thread.report_on_exception and Thread.report_on_exception = true

# If there are problems, this is the most time we'll wait (in seconds).
MAX_BACKOFF = 12.8

VOTE_RECHARGE_PER_DAY = 20.0
VOTE_RECHARGE_PER_HOUR = VOTE_RECHARGE_PER_DAY / 24
VOTE_RECHARGE_PER_MINUTE = VOTE_RECHARGE_PER_HOUR / 60
VOTE_RECHARGE_PER_SEC = VOTE_RECHARGE_PER_MINUTE / 60

@config_path = __FILE__.sub(/\.rb$/, '.yml')
@disabled_voter_path = __FILE__.sub(/\.rb$/, '-disabled-voters.txt')
@account_history = {}

unless File.exist? @config_path
  puts "Unable to find: #{@config_path}"
  exit
end

def parse_voters(voters)
  case voters
  when String
    raise "Not found: #{voters}" unless File.exist? voters

    hash = {}

    File.open(voters, 'r').each do |line|
      key, value = line.split(' ')
      hash[key] = value if !!key && !!hash
    end

    hash
  when Array
    a = voters.map{ |v| v.split(' ')}.flatten.each_slice(2)

    return a.to_h if a.respond_to? :to_h

    hash = {}

    voters.each_with_index do |e|
      key, val = e.split(' ')
      hash[key] = val
    end

    hash
  else; raise "Unsupported voters: #{voters}"
  end
end

def parse_list(list)
  if !!list && File.exist?(list)
    elements = []

    File.open(list, 'r').each do |line|
      elements += line.split(' ')
    end

    elements.uniq.reject(&:empty?).reject(&:nil?)
  else
    list.to_s.split(' ')
  end
end

def parse_slug(slug)
  slug = slug.downcase.split('@').last
  return [] if slug.nil?
  
  author_name = slug.split('/')[0]
  permlink = slug.split('/')[1..-1].join('/')
  permlink = permlink.split('?')[0]
  permlink = permlink.sub(/\/$/, '')
  permlink = permlink.sub(/#comments$/, '')
  
  [author_name, permlink]
end

@config = YAML.load_file(@config_path)
rules = @config[:voting_rules]

@voting_rules = {
  vote_weight: rules[:vote_weight],
  min_transfer: rules[:min_transfer],
  min_transfer_asset: rules[:min_transfer].to_s.split(' ').last,
  min_transfer_amount: rules[:min_transfer].to_s.split(' ').first.to_f,
  max_transfer: rules[:max_transfer],
  max_transfer_asset: rules[:max_transfer].to_s.split(' ').last,
  max_transfer_amount: rules[:max_transfer].to_s.split(' ').first.to_f,
  only_above_average_transfers: rules[:only_above_average_transfers],
  history_limit: rules[:history_limit].to_i,
  enable_comments: rules[:enable_comments],
  min_wait: rules[:min_wait].to_i,
  max_wait: rules[:max_wait].to_i,
  min_voting_power: (((rules[:min_voting_power] || '0.0 %').to_f) * 100).to_i,
  reserve_voting_power: (((rules[:reserve_voting_power] || '0.0 %').to_f) * 100).to_i,
  max_age: rules[:max_age].to_i,
}

unless @voting_rules[:vote_weight] == 'dynamic'
  @voting_rules[:vote_weight] = (((@voting_rules[:vote_weight] || '100.0 %').to_f) * 100).to_i
end

@voting_rules[:wait_range] = [@voting_rules[:min_wait]..@voting_rules[:max_wait]]

unless @voting_rules[:min_rep] =~ /dynamic:[0-9]+/
  @voting_rules[:min_rep] = @voting_rules[:min_rep].to_f
end

@voting_rules = Struct.new(*@voting_rules.keys).new(*@voting_rules.values)

@voters = parse_voters(@config[:voters])
@bots = parse_list(@config[:bots])
@skip_accounts = parse_list(@config[:skip_accounts])
@skip_tags = parse_list(@config[:skip_tags])
@only_tags = parse_list(@config[:only_tags])
@skip_apps = parse_list(@config[:skip_apps])
@only_apps = parse_list(@config[:only_apps])
@flag_signals = parse_list(@config[:flag_signals])
@vote_signals = parse_list(@config[:vote_signals])

@options = @config[:chain_options]
@options[:logger] = Logger.new(__FILE__.sub(/\.rb$/, '.log'))

@voted_for_authors = {}
@voting_power = {}
@api = nil
@follow_api = nil
@stream = nil
@threads = nil
@semaphore = Mutex.new

def to_rep(raw)
  raw = raw.to_i
  neg = raw < 0
  level = Math.log10(raw.abs)
  level = [level - 9, 0].max
  level = (neg ? -1 : 1) * level
  level = (level * 9) + 25

  level
end

def disabled_voters
  disabled_voters = []

  if File.exist? @disabled_voter_path
    @disabled_voters_h ||= File.open(@disabled_voter_path, 'r')

    @disabled_voters_h.rewind
    @disabled_voters_h.each do |line|
      disabled_voters << line.split(' ').first
    end
  end

  disabled_voters
end

def active_voters
  @voters.keys - disabled_voters
end

def poll_voting_power
  @semaphore.synchronize do
    @api.get_accounts(active_voters) do |accounts|
      if accounts.size == 0
        @min_voting_power = 0
        @max_voting_power = 0
        @average_voting_power = 0

        return 0
      end

      accounts.each do |account|
        voting_power = account.voting_power / 100.0
        last_vote_time = Time.parse(account.last_vote_time + 'Z')
        voting_elapse = Time.now.utc - last_vote_time
        current_voting_power = voting_power + (voting_elapse * VOTE_RECHARGE_PER_SEC)
        wasted_voting_power = [current_voting_power - 100.0, 0.0].max
        current_voting_power = ([100.0, current_voting_power].min * 100).to_i

        if wasted_voting_power > 0
          puts "\t#{account.name} wasted voting power: #{('%.2f' % wasted_voting_power)} %"
        end

        @voting_power[account.name] = current_voting_power
      end

      @min_voting_power = @voting_power.values.min
      @max_voting_power = @voting_power.values.max
      @average_voting_power = @voting_power.values.reduce(0, :+) / accounts.size
    end
  end
end

def summary_voting_power
  poll_voting_power
  vp = @average_voting_power / 100.0
  summary = []

  summary << if @voting_power.size > 1
    "Average remaining voting power: #{('%.3f' % vp)} %"
  else
    "Remaining voting power: #{('%.3f' % vp)} %"
  end

  if @voting_power.size > 1 && @max_voting_power > @voting_rules.min_voting_power
    vp = @max_voting_power / 100.0

    summary << "highest account: #{('%.3f' % vp)} %"
  end

  vp = @voting_rules.min_voting_power / 100.0
  summary << "recharging when below: #{('%.3f' % vp)} %"

  if @voting_rules.reserve_voting_power > 0
    summary << "reserve voting power: #{'%.3f' % (@voting_rules.reserve_voting_power / 100.0)} %"
  end

  summary.join('; ')
end

def voters_recharging(weight)
  target_voting_power = if weight < 10000
    @voting_rules.min_voting_power
  else
    @voting_rules.min_voting_power - @voting_rules.reserve_voting_power
  end

  @voting_power.map do |voter, power|
    voter if power < target_voting_power
  end.compact
end

def account_history(bot)
  @account_history[bot] = nil if rand < 0.05
  limit = @voting_rules.history_limit

  if @account_history[bot].nil?
    args = [bot, -limit, limit]
    @account_history[bot] = @api.get_account_history(*args) do |history, error|
      history unless !!error
    end
  else
    limit = (limit / 10).to_i
    if limit > 0
      args = [bot, -limit, limit]
      @account_history[bot] += @api.get_account_history(*args) do |history, error|
        history unless !!error
      end

      @account_history[bot] = @account_history[bot].uniq
    end
  end

  @account_history[bot]
end

def average_transfer(bot, asset)
  inputs = account_history(bot).map do |index, transaction|
    type, op = transaction.op
    next unless type == 'transfer'
    next unless op.to == bot
    next unless op.amount =~ /#{asset}$/

    op.amount.split(' ').first.to_f
  end.compact

  sum = inputs.reduce(0, :+)
  return true if sum == 0.0

  sum / inputs.size
end

def above_average_transfer?(bot, amount, asset)
  amount > average_transfer(bot, asset)
end

def max_transfer(bot, asset)
  inputs = account_history(bot).map do |index, transaction|
    type, op = transaction.op
    next unless type == 'transfer'
    next unless op.to == bot
    next unless op.amount =~ /#{asset}$/

    op.amount.split(' ').first.to_f
  end.compact

  inputs.max || 0.0
end

def skip_tags_intersection?(json_metadata)
  metadata = JSON[json_metadata || '{}'] rescue []
  tags = metadata['tags'] || [] rescue []
  tags = [tags].flatten

  (@skip_tags & tags).any?
end

def only_tags_intersection?(json_metadata)
  return true if @only_tags.none? # not set, assume all tags intersect

  metadata = JSON[json_metadata || '{}'] rescue []
  tags = metadata['tags'] || [] rescue []
  tags = [tags].flatten

  (@only_tags & tags).any?
end

def skip_app?(json_metadata)
  metadata = JSON[json_metadata || '{}'] rescue ''
  app = metadata['app'].to_s.split('/').first

  @skip_apps.include? app
end

def only_app?(json_metadata)
  return true if @only_apps.none?

  metadata = JSON[json_metadata || '{}'] rescue ''
  app = metadata['app'].to_s.split('/').first

  @only_apps.include? app
end

def valid_transfer?(transfer)
  to = transfer.to
  amount = transfer.amount.split(' ').first.to_f
  asset = transfer.amount.split(' ').last

  return false unless @bots.include? to
  return false if @voting_rules.only_above_average_transfers && !above_average_transfer?(to, amount, asset)

  if !@voting_rules.min_transfer.nil?
    return false unless asset == @voting_rules.min_transfer_asset
    return false unless amount >= @voting_rules.min_transfer_amount
  end

  if !@voting_rules.max_transfer.nil?
    return false unless asset == @voting_rules.max_transfer_asset
    return false unless amount <= @voting_rules.max_transfer_amount
  end

  true
end

# The rationale here is to find out if the bots have already voted because
# there's no way to front-run if this happens, so we need to know if this
# comment should be skipped.
def bots_already_voted?(comment)
  all_voters = comment.active_votes.map(&:voter)

  (all_voters & @bots).any?
end

def may_vote?(comment)
  return false if !@voting_rules.enable_comments && !comment.parent_author.empty?
  return false if @skip_tags.include? comment.parent_permlink
  return false if skip_tags_intersection? comment.json_metadata
  return false unless only_tags_intersection? comment.json_metadata
  return false if @skip_accounts.include? comment.author
  return false if skip_app? comment.json_metadata
  return false unless only_app? comment.json_metadata
  return false if bots_already_voted?(comment)

  true
end

def min_trending_rep(limit)
  begin
    @semaphore.synchronize do
      if @min_trending_rep.nil? || Random.rand(0..limit) == 13
        puts "Looking up trending up to #{limit} transfers."

        response = @api.get_discussions_by_trending(tag: '', limit: limit)
        raise response.error.message if !!response.error

        trending = response.result
        @min_trending_rep = trending.map do |c|
          c.author_reputation.to_i
        end.min

        puts "Current minimum dynamic rep: #{('%.3f' % to_rep(@min_trending_rep))}"
      end
    end
  rescue => e
    puts "Warning: #{e}"
  end
  
  @min_trending_rep || 0
end

def skip?(comment, voters)
  if bots_already_voted?(comment)
    puts "Skipped, cannot front-run:\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  if comment.respond_to? :cashout_time # HF18
    if (cashout_time = Time.parse(comment.cashout_time + 'Z')) < Time.now.utc
      puts "Skipped, cashout time has passed (#{cashout_time}):\n\t@#{comment.author}/#{comment.permlink}"
      return true
    end
  end

  if ((Time.now.utc - (created = Time.parse(comment.created + 'Z'))).to_i / 60) > @voting_rules.max_age
    puts "Skipped, too old (#{created}):\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  if comment.max_accepted_payout.split(' ').first == '0.000'
    puts "Skipped, payout declined:\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  if active_voters.empty?
    puts "Skipped, everyone already voted:\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  downvoters = comment.active_votes.map do |v|
    v.voter if v.percent < 0
  end.compact

  if (signal = downvoters & @flag_signals).any?
    # ... Got a signal flag ...
    puts "Skipped, flag signals (#{signals.join(' ')} flagged):\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  upvoters = comment.active_votes.map do |v|
    v.voter if v.percent > 0
  end.compact

  if (signals = upvoters & @vote_signals).any?
    # ... Got a signal vote ...
    puts "Skipped, vote signals (#{signals.join(' ')} voted):\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  all_voters = comment.active_votes.map(&:voter)

  if (all_voters & voters).any?
    # ... Someone already voted (probably because post was edited) ...
    puts "Skipped, already voted:\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end

  false
end

def vote_weight(transfer)
  return @voting_rules.vote_weight unless @voting_rules.vote_weight == 'dynamic'

  bot = transfer.to
  amount, asset = transfer.amount.split(' ')
  amount = amount.to_f
  max = max_transfer(bot, asset)

  if amount >= max
    10000 # full vote
  else
    ((amount / max) * 10000).to_i
  end
end

def async_vote(comment, wait_offset, transfer)
  slug = "@#{comment.author}/#{comment.permlink}"

  @threads.each do |k, t|
    @threads.delete(k) unless t.alive?
  end

  @semaphore.synchronize do
    if @threads.size != @last_threads_size
      print "Pending votes: #{@threads.size} ... "
      @last_threads_size = @threads.size
    end
  end

  if @threads.keys.include? slug
    puts "Skipped, vote already pending:\n\t#{slug}"
    return
  end

  @threads[slug] = Thread.new do
    vote(comment, wait_offset, transfer)
  end
end

def vote(comment, wait_offset, transfer)
  votes_cast = 0
  backoff = 0.2
  slug = "@#{comment.author}/#{comment.permlink}"
  weight = vote_weight(transfer)
  voters = active_voters - comment.active_votes.map(&:voter) - voters_recharging(weight)

  return if skip?(comment, voters)

  if wait_offset == 0
    timestamp = Time.parse(comment.created + ' Z')
    now = Time.now.utc
    wait_offset = now - timestamp
  end

  if (wait = (Random.rand(*@voting_rules.wait_range) * 60) - wait_offset) > 0
    puts "Waiting #{wait.to_i} seconds to vote for:\n\t#{slug}"
    sleep wait

    response = @api.get_content(comment.author, comment.permlink)
    comment = response.result

    return if skip?(comment, voters)
  else
    puts "Catching up to vote for:\n\t#{slug}"
    sleep 3
  end

  loop do
    begin
      break if voters.empty?

      author = comment.author
      permlink = comment.permlink
      voter = voters.sample

      break if weight == 0.0

      if (vp = @voting_power[voter].to_i) < @voting_rules.min_voting_power
        vp = vp / 100.0

        if active_voters.size > 1
          puts "Recharging #{voter} vote power (currently too low: #{('%.3f' % vp)} %)"
        else
          puts "Recharging vote power (currently too low: #{('%.3f' % vp)} %)"
        end
      end

      wif = @voters[voter]
      tx = Radiator::Transaction.new(@options.merge(wif: wif, pool_size: 1))

      puts "#{voter} voting for #{slug} (transferred #{transfer.amount} to get #{(weight / 100.0)} % upvote)"

      vote = {
        type: :vote,
        voter: voter,
        author: author,
        permlink: permlink,
        weight: weight
      }

      tx.operations << vote
      response = tx.process(true)

      if !!response.error
        message = response.error.message
        if message.to_s =~ /You have already voted in a similar way./
          puts "\tFailed: duplicate vote."
          voters -= [voter]
          next
        elsif message.to_s =~ /Can only vote once every 3 seconds./
          puts "\tRetrying: voting too quickly."
          sleep 3
          next
        elsif message.to_s =~ /Voting weight is too small, please accumulate more voting power or steem power./
          puts "\tFailed: voting weight too small"
          voters -= [voter]
          next
        elsif message.to_s =~ /tx_missing_posting_auth: missing required posting authority/
          puts "\tFailed: missing required posting authority (#{voter})"
          disable_voter voter, 'missing required posting authority'
          voters -= [voter]
          next
        elsif message.to_s =~ /STEEMIT_UPVOTE_LOCKOUT_HF17/
          puts "\tFailed: upvote lockout (last twelve hours before payout)"
          break
        elsif message.to_s =~ /tapos_block_summary/
          puts "\tRetrying: tapos_block_summary (?)"
          redo
        elsif message.to_s =~ /now < trx.expiration/
          puts "\tRetrying: now < trx.expiration (?)"
          redo
        elsif message.to_s =~ /transaction_expiration_exception: transaction expiration exception/
          puts "\tRetrying: transaction_expiration_exception: transaction expiration exception"
          redo
        elsif message.to_s =~ /signature is not canonical/
          puts "\tRetrying: signature was not canonical (bug in Radiator?)"
          redo
        end

        ap response
        raise message
      else
        voters -= [voter]
      end

      puts "\tSuccess: #{response.result.to_json}"
      @voted_for_authors[author] = Time.now.utc
      votes_cast += 1

      next
    rescue => e
      puts "Pausing #{backoff} :: Unable to vote with #{voter}.  #{e.class} :: #{e}"
      disable_voter voter, 'bad wif' if e.inspect =~ /Invalid version/i
      voters -= [voter]
      sleep backoff
      backoff = [backoff * 2, MAX_BACKOFF].min
    end
  end
end

def disable_voter(voter, reason)
  return if disabled_voters.include? voter

  File.open(@disabled_voter_path, 'a+') do |f|
    f.puts "#{voter} # #{reason}"
  end
end

puts "Accounts voting: #{active_voters.size}"
replay = 0

ARGV.each do |arg|
  if arg =~ /replay:[0-9]+/
    replay = arg.split('replay:').last.to_i rescue 0
  end
end

if replay > 0
  Thread.new do
    @api ||= Radiator::Api.new(@options)
    @follow_api ||= Radiator::FollowApi.new(@options)
    @stream ||= Radiator::Stream.new(@options)

    properties = @api.get_dynamic_global_properties.result
    last_irreversible_block_num = properties.last_irreversible_block_num
    block_number = last_irreversible_block_num - replay

    puts "Replaying from block number #{block_number} ..."

    @api.get_blocks(block_number..last_irreversible_block_num) do |block, number|
      next unless !!block

      timestamp = Time.parse(block.timestamp + ' Z')
      now = Time.now.utc
      elapsed = now - timestamp

      block.transactions.each do |tx|
        tx.operations.each do |type, op|
          if type == 'transfer' && valid_transfer?(op)
            author, permlink = parse_slug(op.memo)
            next if author.nil? || permlink.nil?
            
            comment = @api.get_content(author, permlink).result

            if may_vote?(comment)
              async_vote(comment, elapsed.to_i, op)
            end
          end
        end
      end
    end

    sleep 3
    puts "Done replaying."
  end
end

puts "Now watching for new transfers to: #{@bots.join(', ')}"

loop do
  @api ||= Radiator::Api.new(@options)
  @follow_api ||= Radiator::FollowApi.new(@options)
  @stream ||= Radiator::Stream.new(@options)
  @threads ||= {}
  op_idx = 0
  
  begin
    puts summary_voting_power
    counter = 0
    @stream.operations(:transfer) do |transfer|
      next unless valid_transfer? transfer
      author, permlink = parse_slug(transfer.memo)
      next if author.nil? || permlink.nil?
      comment = @api.get_content(author, permlink).result
      next unless may_vote? comment

      if @max_voting_power < @voting_rules.min_voting_power
        vp = @max_voting_power / 100.0

        puts "Recharging vote power (currently too low: #{('%.3f' % vp)} %)"
        if disabled_voters.any?
          puts "Disabled voters: #{disabled_voters.size}"
        end
      end

      async_vote(comment, 0, transfer)
      puts summary_voting_power
    end
  rescue => e
   @api.shutdown
   @api = nil
   @follow_api.shutdown
   @follow_api = nil
   @stream.shutdown
   @stream = nil
   @threads = nil
   puts "Unable to stream on current node.  Retrying in 5 seconds.  Error: #{e}"
   puts e.backtrace
   sleep 5
  end
end
