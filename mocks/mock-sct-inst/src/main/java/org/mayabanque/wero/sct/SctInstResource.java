package org.mayabanque.wero.sct;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import java.util.UUID;

@Path("/sct-inst/transfers")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class SctInstResource {
    @POST
    public TransferResponse transfer(TransferRequest request) {
        return new TransferResponse("SCT-" + UUID.randomUUID(), "SETTLED");
    }

    public record TransferRequest(String paymentId, long amountCents, String currency) {}
    public record TransferResponse(String settlementId, String status) {}
}
