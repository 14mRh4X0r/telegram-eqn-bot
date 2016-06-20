#!/usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'
require 'telegram/bot'
require 'hashie'
require 'logger'

require_relative 'config'

def render id, text
  s = nil

  path = "tmp/#{id}"
  Dir.mkdir path, 0700
  Dir.chdir path do
    File.open('render.tex', 'w') do |file|
      file.write <<EOF
\\documentclass[preview]{standalone}
\\usepackage{mathtools,esint}
\\begin{document}
  $\\displaystyle
    #{text}
  $
\\end{document}
EOF
    end

    res = system 'pdflatex -no-shell-escape -interaction=nonstopmode render.tex >& /dev/null'
    $logger.warn { "Got nonzero exit code when running pdflatex for #{id}" } unless res

    s = StringIO.new `convert -density 300 render.pdf -quality 90 webp:-`

    Dir.foreach '.' do |entry|
      File.delete entry unless File.directory? entry
    end
  end
  Dir.rmdir path

  if $? != 0
    $logger.warn { "Got nonzero exit code when running convert: #{$?}" }
    'error.webp'
  else
    s
  end
end

Telegram::Bot::Client.run(BOT_TOKEN) do |bot|
  $logger = Logger.new STDOUT
  $logger.datetime_format = '%Y-%m-%d %H:%M:%S'
  me = Hashie::Mash.new(bot.api.get_me).result

  $logger.info {"Starting listen"}

  begin
    bot.listen do |msg|
      $logger.debug "Got message: #{msg.respond_to?(:id) ? msg.id : msg.message_id}: #{msg} (#{msg.class})"

      case msg
        when Telegram::Bot::Types::Message
          if msg.text and msg.text[0] == '/'
            cmd = msg.text.split[0][1..-1]
            cmd, who = cmd.split '@' if cmd.include? '@'
            next if not cmd.eql? 'render' or not who.nil? and not who.eql? me.username

            fork do
              io = render "#{msg.message_id}-#{msg.chat.id}", msg.text[('/render '.length)..-1]
              bot.api.send_sticker chat_id: msg.chat.id,
                                   #reply_to_message_id: msg.message_id,
                                   sticker: Faraday::UploadIO.new(io, 'image/webp')
            end
          end
        when Telegram::Bot::Types::InlineQuery
          if msg.query.empty?
            res = [Telegram::Bot::Types::InlineQueryResultArticle.new(
                id: -1,
                title: 'Error',
                input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(message_text: 'No input given.')
            )]
            bot.api.answer_inline_query inline_query_id: msg.id,
                                        results: res
          else
            fork do
              # Hack: we can't send a sticker directly, so send the bot group the sticker first to get a file id
              io = render msg.id, msg.query
              sticker = Hashie::Mash.new(
                  bot.api.send_sticker chat_id: SPAM_CHAT_ID,
                                       sticker: Faraday::UploadIO.new(io, 'image/webp')
              ).result.sticker
              $logger.debug {"Got sticker file id: #{sticker.file_id}"}
              res = [Telegram::Bot::Types::InlineQueryResultCachedSticker.new(
                  id: msg.id,
                  sticker_file_id: sticker.file_id
              )]
              bot.api.answer_inline_query inline_query_id: msg.id,
                                          results: res
            end
          end
      end
    end
  rescue Interrupt
    $logger.warn 'Caught interrupt -- quitting'
  end
end
