package org.mayabanque.wero.payment;

import io.quarkus.panache.common.Page;
import io.quarkus.scheduler.Scheduled;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;
import java.time.Instant;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class OutboxPublisher {

    @ConfigProperty(name = "kafka.bootstrap.servers")
    String bootstrapServers;

    @ConfigProperty(name = "wero.events.topic", defaultValue = "payment-events")
    String topic;

    @ConfigProperty(name = "wero.outbox.batch-size", defaultValue = "50")
    int batchSize;

    KafkaProducer<String, String> producer;

    @PostConstruct
    void init() {
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");
        props.put(ProducerConfig.CLIENT_ID_CONFIG, "mayabanque-payment-outbox");
        producer = new KafkaProducer<>(props);
    }

    @PreDestroy
    void close() {
        if (producer != null) {
            producer.close();
        }
    }

    @Scheduled(every = "1s", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    @Transactional
    void publishBatch() {
        List<OutboxEventEntity> pending = OutboxEventEntity
                .find("publishedAt is null order by id")
                .page(Page.ofSize(batchSize))
                .list();

        for (OutboxEventEntity row : pending) {
            try {
                ProducerRecord<String, String> record = new ProducerRecord<>(topic, row.aggregateId, row.payload);
                producer.send(record).get(3, TimeUnit.SECONDS);
                row.publishedAt = Instant.now();
                row.publishAttempts++;
                row.lastError = null;
            } catch (Exception e) {
                row.publishAttempts++;
                row.lastError = truncate(e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()), 500);
            }
        }
    }

    private static String truncate(String value, int max) {
        if (value == null || value.length() <= max) return value;
        return value.substring(0, max);
    }
}
