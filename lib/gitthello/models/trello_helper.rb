module Gitthello
  class TrelloHelper
    attr_reader :list_todo, :list_pr, :list_done, :github_urls, :board

    # https://trello.com/docs/api/card/#put-1-cards-card-id-or-shortlink
    MAX_TEXT_LENGTH=16384
    TRUNCATION_MESSAGE = "... [truncated by gitthello]"

    def initialize(token, dev_key, board_name)
      Trello.configure do |cfg|
        cfg.member_token         = token
        cfg.developer_public_key = dev_key
      end
      @board_name = board_name
    end

    def setup
      @board = retrieve_board

      @list_todo    = @board.lists.select { |a| a.name == 'Issues' }.first
      raise "Missing trello To Do list" if list_todo.nil?

      @list_pr    = @board.lists.select { |a| a.name == 'Open PRs' }.first
      raise "Missing trello PR list" if list_todo.nil?

      @list_done    = @board.lists.select { |a| a.name == 'Done / For Retro' }.first
      raise "Missing trello Done list" if list_done.nil?

      @github_urls = all_github_urls
      puts "Found #{@github_urls.count} github urls"
      self
    end

    def archive_done
      old_pos = @list_done.pos
      @list_done.name = "Done KW#{Time.now.strftime('%W')}"
      @list_done.save
      @list_done.close!

      @list_done = Trello::List.create(:name => "Done", :board_id=> @board.id)
      @list_done.pos = old_pos+1
      @list_done.save
    end

    def has_card?(issue)
      @github_urls.include?(issue["html_url"])
    end

    def create_todo_card(name, desc, issue_url, is_pull_request)
      create_card_in_list(name, desc, issue_url, is_pull_request ? list_pr.id : list_todo.id, is_pull_request)
    end

    #
    # Close github issues that have been moved to the done list but only
    # if the ticket has been reopened, i.e. updated_at timestamp is
    # newer than the card.
    #
    def close_issues(github_helper)
      list_done.cards.each do |card|
        github_details = obtain_github_details(card)
        next if github_details.nil?

        user,repo,_,number = github_details.url.split(/\//)[3..-1]
        issue = github_helper.get_issue(user,repo,number)

        if card.last_activity_date > DateTime.strptime(issue.updated_at)
          # if the card was moved more recently than the issue was updated,
          # then close the issue
          github_helper.close_issue(user,repo,number)
        else
          # if the issue was updated more recently than the card and it's
          # open, then move the card to the todo list, i.e. the issue
          # was reopened.
          card.move_to_list(list_todo) if issue.state == "open"
        end
      end
    end

    def move_cards_with_closed_issue(github_helper)
      board.lists.each do |list|
        next if list.id == list_done.id
        list.cards.each do |card|
          d = obtain_github_details(card)
          next if d.nil?
          user,repo,_,number = d.url.split(/\//)[3..-1]
          if github_helper.issue_closed?(user,repo,number)
            card.move_to_list(list_done)
            card.pos = "top"
            card.save
          end
        end
      end
    end

    def new_cards_to_github(github_helper)
      all_cards_not_at_github.each do |card|
        issue = github_helper.create_issue(card.name, card.desc)
        github_helper.add_trello_url(issue, card.url)
        card.add_attachment(issue.html_url, "github")
      end
    end

    def add_trello_link_to_issues(github_helper)
      board.cards.each do |card|
        issue = obtain_issue_for_card(card, github_helper)
        next if issue.nil?

        github_helper.add_trello_url(issue, card.url)
      end
    end

    private

    def obtain_github_details(card)
      card.attachments.select do |a|
        a.name == "github" || a.url =~ /https:\/\/github.com.*issues.*/
      end.first
    end

    def retrieve_board
      Trello::Board.all.select { |b| b.name == @board_name }.first
    end

    def create_card_in_list(name, desc, url, list_id, is_pull_request = false)
      Trello::Card.
        create(:name => truncate_text(name), :list_id => list_id,
               :desc => truncate_text(desc)).tap do |card|
        card.add_attachment(url, "github")
        card.add_label("red") if !is_pull_request
        card.add_label("purple") if is_pull_request
      end
    end

    def obtain_issue_for_card(card, github_helper)
      gd = obtain_github_details(card)
      return if gd.nil?

      user,repo,_,number = gd.url.split(/\//)[3..-1]
      github_helper.get_issue(user,repo,number)
    end

    def all_cards_not_at_github
      board.lists.map do |a|
        a.cards.map do |card|
          obtain_github_details(card).nil? ? card : nil
        end.compact
      end.flatten.reject do |card|
        # ignore new cards in the Done list - for these we don't
        # need to create github issues
        card.list_id == list_done.id
      end
    end

    def all_github_urls
      board.lists.map do |a|
        a.cards.map do |card|
          github_details = obtain_github_details(card)
          github_details.nil? ? nil : github_details.url
        end.compact
      end.flatten
    end

    def truncate_text(text)
      if text && text.length > MAX_TEXT_LENGTH
        text[0, MAX_TEXT_LENGTH - TRUNCATION_MESSAGE.length] + TRUNCATION_MESSAGE
      else
        text
      end
    end
  end
end
