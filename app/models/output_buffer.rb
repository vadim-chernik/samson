# frozen_string_literal: true
require 'thread_safe'

# Allows fanning out a stream to multiple listening threads. Each thread will
# have to call `#each`, and will receive each chunk of data that is written
# to the buffer. If a thread starts listening after the buffer has been written
# to, it will receive the previous chunks immediately and then start streaming
# new chunks.
#
# Example:
#
#   buffer = OutputBuffer.new
#
#   listener1 = Thread.new { c = ""; buffer.each {|event, data| c << data }; c }
#   listener2 = Thread.new { c = ""; buffer.each {|event, data| c << data }; c }
#
#   buffer.write("hello ")
#   buffer.write("world!")
#   buffer.close
#
#   listener1.value #=> "hello world!"
#   listener2.value #=> "hello world!"
#
class OutputBuffer
  attr_reader :listeners

  def initialize
    @listeners = ThreadSafe::Array.new
    @previous = ThreadSafe::Array.new
    @closed = false
  end

  def puts(line = "")
    write(line.to_s.rstrip << "\n")
  end

  def write(data, event = :message)
    @previous << [event, data] unless event == :close
    @listeners.dup.each { |listener| listener.push([event, data]) }
  end

  def write_docker_chunk(chunk)
    parsed_chunk = JSON.parse(chunk)

    # Don't bother printing all the incremental output when pulling images
    unless parsed_chunk['progressDetail']
      if parsed_chunk.keys == ['stream']
        puts parsed_chunk.values.first
      else
        values = parsed_chunk.map { |k, v| "#{k}: #{v}" if v.present? }.compact
        puts values.join(' | ') if values.any?
      end
    end

    parsed_chunk
  rescue JSON::ParserError
    # Sometimes the JSON line is too big to fit in one chunk, so we get
    # a chunk back that is an incomplete JSON object.
    chunk = chunk.encode(Encoding::UTF_8, chunk.encoding, invalid: :replace, undef: :replace)
    puts chunk
    { 'message' => chunk }
  end

  def include?(event, data)
    @previous.include?([event, data])
  end

  def to_s
    @previous.select { |event, _data| event == :message }.map(&:last).join
  end

  def close
    return if closed?
    @closed = true
    write(nil, :close)
  end

  def closed?
    @closed
  end

  def each(&block)
    # If the buffer is closed, there's no reason to block the listening
    # thread - just yield all the buffered chunks and return.
    return @previous.each(&block) if closed?

    begin
      queue = Queue.new
      @listeners << queue

      # race condition: possibly duplicate messages when message comes in between adding listener and this
      @previous.each(&block)

      while (chunk = queue.pop) && chunk.first != :close
        yield chunk
      end
    ensure
      @listeners.delete(queue)
    end
  end
end
