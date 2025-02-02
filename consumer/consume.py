import pika
import os
import requests
import json
import base64
import hashlib
import traceback
import logging

from jsonschema import validate

#logging.basicConfig(format='%(asctime)s %(levelname)s %(message)s')

url = os.environ.get('CLOUDAMQP_URL', 'amqp://guest:guest@localhost:5672/%2f') # the location and username password of the broker
routing_key = os.environ.get('ROUTING_KEY',"mw.#") # topic to subscribe to
out_dir = r"./out" # output directory. Subdirectories corresponding to the topic structure will be created, if needed.

# the JSON grammar of the message structure
schema = json.load(open("message-schema.json"))

DEBUG = os.environ.get('DEBUG',True)
log_level = logging.DEBUG if DEBUG else logging.INFO
logging.basicConfig(level=log_level)
logging.getLogger("pika").setLevel(logging.WARNING)

def parse_mqp_message(message,topic):
    """ Function that receives a MQP notification based on the WIS 2.0 specifications, as well as the routing key (topic).
    Obtains the file of the notification, either from the message directly or via downloading.
    Checks the file integrity and writes out the file into the output directoy, in a folder hirarchy based on the topic.
    """
    
    message = json.loads(message)

    logging.debug( "MQP message: {}".format(message)) 
    
    validate(instance=message, schema=schema) # check if the message structure is valid
    # we only support base64 encoding and sha512 checksum at this point
    if "content" in message and not message["content"]["encoding"] == "base64":
        raise Exception("message encoding not supported")
    if not message["integrity"]["method"] == "sha512":
        raise Exception("message integrity not supported")
       
    # either download message or obtain it directly from the message structure    
    content = base64.b64decode(message["content"]["value"]) if "content" in message else requests.get(message["baseUrl"] + message["relPath"]).content
        
    # check message length and checksum. Only sha512 supported at the moment
    content_hash = base64.b64encode( hashlib.sha512(content).digest() ).decode("utf8")
    if not len(content) == message["size"]:
        raise Exception("integrity issue. Message length expected {} got {}".format(len(content),message["size"]))
    if not content_hash == message["integrity"]["value"]:
        logging.warning("checksum problem. Check old style encoding")
        if not hashlib.sha512(content).hexdigest() == message["integrity"]["value"]:
            raise Exception("integrity issue. Expected checksum {} got {}".format(content_hash,message["integrity"]["value"]))

    path, filename = os.path.split(message["relPath"])
    topic_dir = os.path.join( out_dir , topic.replace(".","/") )
    
    os.makedirs( topic_dir , exist_ok=True )
    out_file = os.path.join(topic_dir,filename)
    with open( out_file , "wb" ) as fp:
        fp.write(content)
        
    logging.info("Obtained and wrote file: {}".format(out_file))

def callback(ch, method, properties, body):
    """callback function, called when a new notificaton arrives"""
    topic = method.routing_key
    
    logging.info("Received message with topic: " + topic )
    try:
        parse_mqp_message(body,topic)
    except Exception as e:
        logging.error("exception during mqp processing: {}".format( traceback.format_exc() ))

def main():

    logging.info("Setting up MQP consumer")

    # connect to the broker
    params = pika.URLParameters(url)
    logging.debug("Connecting to {}".format(params))
    connection = pika.BlockingConnection(params)
    channel = connection.channel()

    # create a queue and bind it to the topic defined above. 
    # The queue will get a random name assigned, which is different across invokations of the script. 
    # This means that messages arriving when not connected will not be received. For this a unique name must be given to the queue.
    result = channel.queue_declare(queue='', exclusive=True)
    queue_name = result.method.queue
    channel.queue_bind(exchange="amq.topic", queue=queue_name, routing_key=routing_key)

    # configure callback function
    channel.basic_consume(queue_name,
                          callback,
                          auto_ack=True)

    # start waiting for messages
    logging.info('Waiting for messages:')
    channel.start_consuming()

    # gracefully stop and close ressources
    connection.close()

if __name__ == "__main__":
    main()
