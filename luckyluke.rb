# Lucky Luke (luckyluke) watches transfers sent to pay-for-vote bots and tries
# to vote for the content first (front-running).
# 
# See: https://steemit.com/radiator/@inertia/luckyluke-rb-voting-bot

require 'rubygems'
require 'bundler/setup'
require 'yaml'
require 'pry'

Bundler.require

# If there are problems, this is the most time we'll wait (in seconds).
MAX_BACKOFF = 12.8

VOTE_RECHARGE_PER_DAY = 20.0
VOTE_RECHARGE_PER_HOUR = VOTE_RECHARGE_PER_DAY / 24
VOTE_RECHARGE_PER_MINUTE = VOTE_RECHARGE_PER_HOUR / 60
VOTE_RECHARGE_PER_SEC = VOTE_RECHARGE_PER_MINUTE / 60

@config_path = __FILE__.sub(/\.rb$/, '.yml')

unless File.exist? @config_path
  puts "Unable to find: #{@config_path}"
  exit
end

def parse_voters(voters)
  case voters
  when String
    raise "Not found: #{voters}" unless File.exist? voters
    
    f = File.open(voters)
    hash = {}
    f.read.each_line do |pair|
      key, value = pair.split(' ')
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
    f = File.open(list)
    elements = []
    
    f.each_line do |line|
      elements += line.split(' ')
    end
    
    elements.uniq.reject(&:empty?).reject(&:nil?)
  else
    list.to_s.split(' ')
  end
end

def parse_slug(slug)
  slug = slug.downcase.split('@').last
  author_name = slug.split('/')[0]
  permlink = slug.split('/')[1..-1].join('/')
  permlink = permlink.split('?')[0]
    
  [author_name, permlink]
end

@config = YAML.load_file(@config_path)
rules = @config[:voting_rules]

@voting_rules = {
  vote_weight: (((rules[:vote_weight] || '100.0 %').to_f) * 100).to_i,
  min_transfer: rules[:min_transfer],
  min_transfer_asset: rules[:min_transfer].to_s.split(' ').last,
  min_transfer_amount: rules[:min_transfer].to_s.split(' ').first.to_f,
  max_transfer: rules[:max_transfer],
  max_transfer_asset: rules[:max_transfer].to_s.split(' ').last,
  max_transfer_amount: rules[:max_transfer].to_s.split(' ').first.to_f,
  enable_comments: rules[:enable_comments],
  min_wait: rules[:min_wait].to_i,
  max_wait: rules[:max_wait].to_i,
  min_voting_power: (((rules[:min_voting_power] || '0.0 %').to_f) * 100).to_i,
}

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
@threads = {}
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

def poll_voting_power
  @semaphore.synchronize do
    response = @api.get_accounts(@voters.keys)
    accounts = response.result
    
    accounts.each do |account|
      voting_power = account.voting_power / 100.0
      last_vote_time = Time.parse(account.last_vote_time + 'Z')
      voting_elapse = Time.now.utc - last_vote_time
      current_voting_power = voting_power + (voting_elapse * VOTE_RECHARGE_PER_SEC)
      current_voting_power = [10000, current_voting_power].min.to_i * 100
      
      @voting_power[account.name] = current_voting_power
    end
    
    @min_voting_power = @voting_power.values.min
    @max_voting_power = @voting_power.values.max
    @average_voting_power = @voting_power.values.reduce(0, :+) / accounts.size
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
  
  summary.join('; ')
end

def voters_recharging
  @voting_power.map do |voter, power|
    voter if power < @voting_rules.min_voting_power
  end.compact
end

def skip_tags_intersection?(json_metadata)
  metadata = JSON[json_metadata || '{}']
  tags = metadata['tags'] || [] rescue []
  tags = [tags].flatten
  
  (@skip_tags & tags).any?
end

def only_tags_intersection?(json_metadata)
  return true if @only_tags.none? # not set, assume all tags intersect
  
  metadata = JSON[json_metadata || '{}']
  tags = metadata['tags'] || [] rescue []
  tags = [tags].flatten
  
  (@only_tags & tags).any?
end

def skip_app?(json_metadata)
  metadata = JSON[json_metadata || '{}']
  app = metadata['app'].to_s.split('/').first
  
  @skip_apps.include? app
end

def only_app?(json_metadata)
  return true if @only_apps.none?
  
  metadata = JSON[json_metadata || '{}']
  app = metadata['app'].to_s.split('/').first
  
  @only_apps.include? app
end

def valid_transfer?(transfer)
  return false unless @bots.include? transfer.to
  
  if !@voting_rules.min_transfer.nil?
    return false unless transfer.amount.split(' ').last == @voting_rules.min_transfer_asset
    return false unless transfer.amount.split(' ').first.to_f >= @voting_rules.min_transfer_amount
  end
  
  if !@voting_rules.max_transfer.nil?
    return false unless transfer.amount.split(' ').last == @voting_rules.max_transfer_asset
    return false unless transfer.amount.split(' ').first.to_f <= @voting_rules.max_transfer_amount
  end
  
  true
end

def may_vote?(comment)
  return false if !@voting_rules.enable_comments && !comment.parent_author.empty?
  return false if @skip_tags.include? comment.parent_permlink
  return false if skip_tags_intersection? comment.json_metadata
  return false unless only_tags_intersection? comment.json_metadata
  return false if @skip_accounts.include? comment.author
  return false if skip_app? comment.json_metadata
  return false unless only_app? comment.json_metadata
  
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
  if comment.respond_to? :cashout_time # HF18
    if (cashout_time = Time.parse(comment.cashout_time + 'Z')) < Time.now.utc
      puts "Skipped, cashout time has passed (#{cashout_time}):\n\t@#{comment.author}/#{comment.permlink}"
      return true
    end
  end
  
  if comment.max_accepted_payout.split(' ').first == '0.000'
    puts "Skipped, payout declined:\n\t@#{comment.author}/#{comment.permlink}"
    return true
  end
  
  if voters.empty?
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

def vote(comment, wait_offset = 0)
  votes_cast = 0
  backoff = 0.2
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
    voters = @voters.keys - comment.active_votes.map(&:voter) - voters_recharging
    
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
        weight = @voting_rules.vote_weight
        
        break if weight == 0.0
        
        if (vp = @voting_power[voter].to_i) < @voting_rules.min_voting_power
          vp = vp / 100.0
          
          if @voters.size > 1
            puts "Recharging #{voter} vote power (currently too low: #{('%.3f' % vp)} %)"
          else
            puts "Recharging vote power (currently too low: #{('%.3f' % vp)} %)"
          end
        end
                
        wif = @voters[voter]
        tx = Radiator::Transaction.new(@options.dup.merge(wif: wif))
        
        puts "#{voter} voting for #{slug}"
        
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
          elsif message.to_s =~ /STEEMIT_UPVOTE_LOCKOUT_HF17/
            puts "\tFailed: upvote lockout (last twelve hours before payout)"
            break
          elsif message.to_s =~ /signature is not canonical/
            puts "\tRetrying: signature was not canonical (bug in Radiator?)"
            redo
          end
          raise message
        else
          voters -= [voter]
        end
        
        puts "\tSuccess: #{response.result.to_json}"
        @voted_for_authors[author] = Time.now.utc
        votes_cast += 1
        
        next
      rescue => e
        puts "Pausing #{backoff} :: Unable to vote with #{voter}.  #{e}"
        voters -= [voter]
        sleep backoff
        backoff = [backoff * 2, MAX_BACKOFF].min
      end
    end
  end
end

puts "Accounts voting: #{@voters.size}"
replay = 0
  
ARGV.each do |arg|
  if arg =~ /replay:[0-9]+/
    replay = arg.split('replay:').last.to_i rescue 0
  end
end

if replay > 0
  Thread.new do
    @api = Radiator::Api.new(@options.dup)
    @follow_api = Radiator::FollowApi.new(@options.dup)
    @stream = Radiator::Stream.new(@options.dup)
    
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
            comment = @api.get_content(author, permlink).result
            
            if may_vote?(comment)
              vote(comment, elapsed.to_i)
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
  @api = Radiator::Api.new(@options.dup)
  @follow_api = Radiator::FollowApi.new(@options.dup)
  @stream = Radiator::Stream.new(@options.dup)
  op_idx = 0
  
  begin
    puts summary_voting_power
    counter = 0
    @stream.operations(:transfer) do |transfer|
      next unless valid_transfer? transfer
      author, permlink = parse_slug(transfer.memo)
      comment = @api.get_content(author, permlink).result
      next unless may_vote? comment
      
      if @max_voting_power < @voting_rules.min_voting_power
        vp = @max_voting_power / 100.0
        
        puts "Recharging vote power (currently too low: #{('%.3f' % vp)} %)"
      end
      
      vote(comment)
      puts summary_voting_power
    end
  rescue => e
    @api.shutdown
    puts "Unable to stream on current node.  Retrying in 5 seconds.  Error: #{e}"
    puts e.backtrace
    sleep 5
  end
end
