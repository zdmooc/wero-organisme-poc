package org.mayabanque.wero.audit;

import io.quarkus.scheduler.Scheduled;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.time.Duration;
import java.util.List;
import java.util.Properties;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class AuditKafkaConsumer {

    private static final Logger LOG = Logger.getLogger(AuditKafkaConsumer.class);

    @ConfigProperty(name = "kafka.bootstrap.servers")
    String bootstrapServers;

    @ConfigProperty(name = "wero.events.topic", defaultValue = "payment-events")
    String topic;

    @ConfigProperty(name = "wero.audit.group-id", defaultValue = "payment-audit-v1")
    String groupId;

    @Inject
    AuditStore store;

    KafkaConsumer<String, String> consumer;

    @PostConstruct
    void init() {
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.GROUP_ID_CONFIG, groupId);
        props.put(ConsumerConfig.CLIENT_ID_CONFIG, "mayabanque-event-audit");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, "100");
        consumer = new KafkaConsumer<>(props);
        consumer.subscribe(List.of(topic));
    }

    @PreDestroy
    void close() {
        if (consumer != null) {
            consumer.close();
        }
    }

    @Scheduled(every = "1s", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    void poll() {
        try {
            ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(250));
            if (records.isEmpty()) {
                return;
            }
            for (ConsumerRecord<String, String> record : records) {
                store.store(record);
            }
            consumer.commitSync();
        } catch (Exception e) {
            LOG.warnf("Kafka audit poll failed: %s", e.getMessage());
        }
    }
}
