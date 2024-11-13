# frozen_string_literal: true

require "asciidoctor"
require "nokogiri"
require "octokit"
require "open-uri"
require "pathname"
require_relative "book"

def expand(content, path, &get_content)
  content.gsub(/include::(\S+)\[\]/) do |_line|
    if File.dirname(path) == "."
      new_fname = $1
    else
      new_fname = (Pathname.new(path).dirname + Pathname.new($1)).cleanpath.to_s
    end
    new_content = get_content.call(new_fname)
    if new_content
      expand(new_content.delete("\xEF\xBB\xBF"), new_fname) { |c| get_content.call(c) }
    else
      puts "#{new_fname} could not be resolved for expansion"
      ""
    end
  end
end

def genbook(language_code, &get_content)
  nav = '<div id="nav"><a href="{{< previous-section >}}">prev</a> | <a href="{{< next-section >}}">next</a></div>'

  progit = get_content.call("progit.asc")

  chapters = {}
  appnumber = 0
  chnumber = 0
  secnumber = 0

  # The chapter files are historically located in book/<chapter_name>/1-<chapter_name>.asc
  # The new localisation of these files are at the root of the project
  chapter_files = /(book\/[01A-C].*\/1-[^\/]*?\.asc|(?:ch[0-9]{2}|[ABC])-[^\/]*?\.asc)/
  chaps = progit.scan(chapter_files).flatten

  chaps.each_with_index do |filename, _index|
    # select the chapter files
    if /(book\/[01].*\/1-[^\/]*\.asc|ch[0-9]{2}-.*\.asc)/.match?(filename)
      chnumber += 1
      chapters["ch#{secnumber}"] = ["chapter", chnumber, filename]
      secnumber += 1
    end
    # detect the appendices
    next unless filename =~ /(book\/[ABC].*\.asc|[ABC].*\.asc)/

    appnumber += 1
    chapters["ch#{secnumber}"] = ["appendix", appnumber, filename]
    secnumber += 1
  end

  # we strip the includes that don't match the chapters we want to include
  initial_content = progit.gsub(/include::(.*\.asc)\[\]/) do |match|
    if $1 =~ chapter_files
      match
    else
      ""
    end
  end

  begin
    l10n_file = URI.open("https://raw.githubusercontent.com/asciidoctor/asciidoctor/main/data/locale/attributes-#{language_code}.adoc").read
  rescue StandardError => e
    puts "::warning::could not read #{language_code} attributes: #{e}"
    l10n_file = ""
  end
  initial_content.gsub!("include::ch01", l10n_file + "\ninclude::ch01")

  content = expand(initial_content, "progit.asc") { |filename| get_content.call(filename) }
  # revert internal links decorations for ebooks
  content.gsub!(/<<.*?\#(.*?)>>/, "<<\\1>>")

  asciidoc = Asciidoctor::Document.new(content, attributes: { "lang" => language_code })
  html = asciidoc.render
  alldoc = Nokogiri::HTML(html)
  number = 1

  edition = 2
  book = Book.new(edition, language_code)
  book.removeAllFiles()

  alldoc.xpath("//div[@class='sect1']").each_with_index do |entry, index|
    chapter_title = entry.at("h2").content
    if !chapters["ch#{index}"]
      puts "not including #{chapter_title}\n"
      break
    end
    chapter_type, chapter_number = chapters["ch#{index}"]
    chapter = entry

    next if !chapter_title
    next if !chapter_number

    number = chapter_number
    if chapter_type == "appendix"
      number = 100 + chapter_number
    end

    pretext = entry.search("div[@class=sectionbody]/div/p").to_html
    id_xref_chapter = chapter.at("h2").attribute("id").to_s

    schapter = book.chapters[number]
    if schapter.nil?
      book.chapters[number] = schapter = Chapter.new(book)
    end
    schapter.title = chapter_title.to_s
    schapter.chapter_type = chapter_type
    schapter.chapter_number = chapter_number
    schapter.sha = book.sha
    schapter.save

    book_prefix = "book/#{language_code}/v#{edition}/"

    section = 1
    chapter.search("div[@class=sect2]").each do |sec|
      id_xref = sec.at("h3").attribute("id").to_s

      section_title = sec.at("h3").content

      html = sec.inner_html.to_s

      html.gsub!("<h3", "<h2")
      html.gsub!(/\/h3>/, "/h2>")
      html.gsub!("<h4", "<h3")
      html.gsub!(/\/h4>/, "/h3>")
      html.gsub!("<h5", "<h4")
      html.gsub!(/\/h5>/, "/h4>")

      xlink = html.scan(/href="1-.*?\.html\#(.*?)"/)
      xlink&.each do |link|
        xref = link.first
	book.xrefs[xref] = 'redirect-to-en' if !book.xrefs[xref]
        begin
          html.gsub!(/href="1-.*?\.html\##{xref}"/, "href=\"{{< relurl \"#{book_prefix}ch00/#{xref}\" >}}\"")
        rescue StandardError
          nil
        end
      end

      footnotes = Set.new([])

      xlink = html.scan(/href="\#(.*?)"/)
      xlink&.each do |link|
        xref = link.first
        if xref.start_with?('_footnotedef_') || xref.start_with?('_footnoteref_')
          footnotes.add(xref)
          next
        end
	book.xrefs[xref] = 'redirect-to-en' if !book.xrefs[xref]
        begin
          html.gsub!(/href="\##{xref}"/, "href=\"{{< relurl \"#{book_prefix}ch00/#{xref}\" >}}\"")
        rescue StandardError
          nil
        end
      end

      if footnotes.empty?
        footnotes = ''
      else
        @children = alldoc.xpath("//div[@id='footnotes']").children.select do |e|
          e.name != 'div' || footnotes.include?(e.attributes['id'].to_s)
        end
        footnotes = "<div id='footnotes'>#{@children.map{|e| e.to_html}.join('').gsub(/\n\n*/, "\n")}</div>"
      end

      images = []
      subsec = html.scan(/<img src="(.*?)"/)
      subsec&.each do |sub|
        sub = sub.first
        begin
          fixed = book.fixImagePath(sub)
          html.gsub!(/<img src="#{sub}"/, "<img src=\"{{< relurl \"#{book_prefix}#{fixed}\" >}}\"")
          images.append(fixed)
        rescue StandardError
          nil
        end
      end

      puts "\t\t#{chapter_type} #{chapter_number}.#{section} : #{chapter_title} . #{section_title} - #{html.size}"

      csection = schapter.sections[section]
      if csection.nil?
        schapter.sections[section] = csection = Section.new(schapter, section)
      end
      csection.title = section_title.to_s
      csection.html = pretext + html + footnotes + nav

      # create xref
      if section == 1
        book.xrefs[id_xref_chapter] = csection
      end

      images.each do |path|
        content = get_content.call(path)
        csection.saveImage(path, content)
      rescue Errno::ENOENT
        begin
          # Try again with a path relative to the chapter's source file. This
          # used to be common before progit2's d2152ec3 (New architecture of the
          # repository for manual building of the book., 2017-08-28), and not all
          # translations (ahem, `progit2-uz`) managed to merge that commit yet.
          chapter_filename = chapters["ch#{index}"][2]
          path2 = chapter_filename.sub(/[^\/]*$/, path)
          content = get_content.call(path2)
          csection.saveImage(path, content)
        rescue Errno::ENOENT
          puts "::error::referenced image #{path} does not exit!"
        end
      end

      book.xrefs[id_xref] = csection

      # record all the xrefs
      sec.search(".//*[@id]").each do |id|
        id_xref = id.attribute("id").to_s
	book.xrefs[id_xref] = csection if !id_xref.start_with?('_footnoteref_')
      end

      section += 1
      pretext = ""
    end
  end
  book.chapters.each do |chapter|
    next if chapter.nil?
    chapter.sections.each do |section|
      next if section.nil?
      section.save
    end
  end
  book
end

# Generate book html directly from remote git repo
def remote_genbook2(language_code)
  @octokit = Octokit::Client.new(access_token: ENV.fetch("GITHUB_API_TOKEN", nil))

  if language_code
    books = Book.all_books.select { |code, _repo| code == language_code }
  else
    books = Book.all_books.reject do |language_code, repo|
      repo_head = @octokit.commit(repo, "HEAD").sha
      book = Book.where(edition: 2, language_code: language_code).first_or_create
      repo_head == book.sha
    end
  end

  books.each do |language_code, repo|
    blob_content = Hash.new do |blobs, sha|
      content = Base64.decode64(@octokit.blob(repo, sha, encoding: "base64").content)
      blobs[sha] = content.force_encoding("UTF-8")
    end
    repo_head = @octokit.commit(repo, "HEAD")
    repo_tree = @octokit.tree(repo, repo_head.commit.tree.sha, recursive: true)
    book = genbook(language_code) do |filename|
      file_handle = repo_tree.tree.detect { |tree| tree[:path] == filename }
      if file_handle
        blob_content[file_handle[:sha]]
      end
    end

    book.sha = repo_head.sha

    begin
      rel = @octokit.latest_release(repo)
      get_url = lambda do |name_re|
        asset = rel.assets.find { |asset| name_re.match(asset.name) }
        asset&.browser_download_url
      end
      book.ebook_pdf  = get_url.call(/\.pdf$/)
      book.ebook_epub = get_url.call(/\.epub$/)
      book.ebook_mobi = get_url.call(/\.mobi$/)
    rescue Octokit::NotFound
      book.ebook_pdf  = nil
      book.ebook_epub = nil
      book.ebook_mobi = nil
    end

    book.save
  rescue StandardError => e
    puts e.message
  end
end

# Generate book html directly from local git repo"
def local_genbook2(language_code, worktree_path)
  if language_code && worktree_path
    book = genbook(language_code) do |filename|
      File.open(File.join(worktree_path, filename), "r") { |infile| File.read(infile) }
    rescue
      puts "::error::#{filename} is missing!"
      "**ERROR**: _#{filename} is missing_"
    end
    book.sha = `git -C "#{worktree_path}" rev-parse HEAD`.chomp
    if language_code == 'en'
      latest_tag = `git -C "#{worktree_path}" for-each-ref --format '%(refname:short)' --sort=-committerdate --count=1 refs/tags/`.chomp
      if latest_tag.empty?
        puts "No tag found in #{worktree_path}, trying to fetch tags"
        latest_tag = `git -C "#{worktree_path}" fetch --tags origin && git -C "#{worktree_path}" for-each-ref --format '%(refname:short)' --sort=-committerdate --count=1 refs/tags/`.chomp
	raise "Still no tags in #{worktree_path}?" if latest_tag.empty?
      end
      book.ebook_pdf = "https://github.com/progit/progit2/releases/download/#{latest_tag}/progit.pdf"
      book.ebook_epub = "https://github.com/progit/progit2/releases/download/#{latest_tag}/progit.epub"
      book.ebook_mobi = "https://github.com/progit/progit2/releases/download/#{latest_tag}/progit.mobi"
    end
    book.save
  end
end

if ARGV.length == 2
  local_genbook2(ARGV[0], ARGV[1])
elsif ARGV.length == 1
  remote_genbook2(ARGV[0])
else
  abort("Need one or two arguments!")
end
